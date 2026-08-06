# NixOS module for prewarm.
#
# Two units, because warming and locking are different bargains. The warm pass
# is a timer: it costs nothing to hold what it warms, but nothing keeps it
# either, so it repeats. The lock service is long-lived: an mlock lasts exactly
# as long as the process holding it, so the service holds the mappings and does
# nothing else.
#
# Recording is deliberately manual. It has to happen while an app is warm and
# doing the thing you care about, which is a judgement no timer can make.

self:
{
    config,
    lib,
    pkgs,
    ...
}:
let
    cfg = config.services.prewarm;

    named = lib.filterAttrs (_: p: p.files != [ ]) cfg.profiles;

    # One file per profile rather than one big list, so `prewarm status` can
    # still report them apart -- which is the point of naming them.
    declared = pkgs.linkFarm "prewarm-profiles" (
        lib.mapAttrsToList (name: p: {
            name = "${name}.files";
            path = pkgs.writeText "${name}.files" (lib.concatLines p.files);
        }) named
    );

    allWarmDirs = cfg.warmDirs ++ lib.concatMap (p: p.dirs) (lib.attrValues cfg.profiles);

    environment =
        {
            PREWARM_STATE_DIR = cfg.stateDir;
            PREWARM_PROFILE_DIRS = lib.concatStringsSep ":" (
                [ cfg.stateDir ] ++ lib.optional (named != { }) "${declared}"
            );
            PREWARM_MIN_SIZE = toString cfg.minSize;
            PREWARM_MAX_LOCKED = toString cfg.maxLocked;
            PREWARM_WARM_DIRS = lib.concatStringsSep ":" allWarmDirs;
        }
        // lib.optionalAttrs (cfg.prefix != null) { PREWARM_PREFIX = cfg.prefix; };
in
{
    options.services.prewarm = {
        enable = lib.mkEnableOption "keeping the pages applications need resident";

        package = lib.mkOption {
            type = lib.types.package;
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
            defaultText = lib.literalExpression "prewarm.packages.\${system}.default";
            description = "The prewarm package to install and run.";
        };

        stateDir = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/prewarm";
            description = "Where recorded profiles are kept.";
        };

        group = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = ''
                Group allowed to write the state directory, so recording a
                profile does not need root.
            '';
        };

        minSize = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = ''
                Smallest file, in bytes, to record page ranges for. 0 records
                every mapped file, which is usually what you want -- the ranges
                are the pages actually faulted in either way, so a small file
                costs little to include.
            '';
        };

        prefix = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "/nix/store";
            description = ''
                Only record mappings under this path. Keeps a recording from
                pinning an app's own data files, which change, rather than the
                code it maps, which does not.
            '';
        };

        maxLocked = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = ''
                Ceiling on locked bytes, or 0 for no limit. Worth keeping ahead
                of what is recorded rather than trimming to fit: the cap drops
                whatever sorts last by path, which is arbitrary rather than
                least useful.
            '';
        };

        profiles = lib.mkOption {
            default = { };
            description = ''
                Named sets of things to keep resident, declared rather than
                recorded.

                Worth preferring to `prewarm record` where you already know what
                an application needs. A recorded profile names exact
                /nix/store paths and is invalidated by the next update, with
                nothing to notice that it has been; a declared one is written
                from the same expression that builds the system, so it is
                rewritten whenever those paths change.

                Recorded profiles still win where the answer is not obvious --
                they carry the pages actually faulted in, rather than whole
                files. The two are read together and merged.
            '';
            example = lib.literalExpression ''
                {
                    epiphany = {
                        files = [ "''${pkgs.epiphany}/bin/epiphany" ];
                        dirs = [ "/home/someone/.local/share/epiphany" ];
                    };
                }
            '';
            type = lib.types.attrsOf (
                lib.types.submodule {
                    options = {
                        files = lib.mkOption {
                            type = lib.types.listOf lib.types.str;
                            default = [ ];
                            description = ''
                                Files to keep resident whole. Missing paths are
                                skipped, so listing something optional is safe.
                            '';
                        };

                        dirs = lib.mkOption {
                            type = lib.types.listOf lib.types.str;
                            default = [ ];
                            description = ''
                                Directories to warm whole, walked live. Warmed
                                only, never locked -- see warmDirs.
                            '';
                        };
                    };
                }
            );
        };

        warmDirs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "/home/someone/.local/share/weblaunch" ];
            description = ''
                Directories to read into the page cache whole, walked live
                rather than recorded. For data an app reads instead of maps --
                browser profiles and caches -- where a recorded file list would
                go stale as the app rewrites it.
            '';
        };

        interval = lib.mkOption {
            type = lib.types.str;
            default = "1h";
            description = ''
                How often to repeat the warm pass. Warmed pages are evictable,
                so without this nothing puts them back. A repeat pass over
                already-resident pages is cheap; only the first one is not.
            '';
        };

        lock = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
                Whether to hold the recorded ranges with mlock as well as
                warming them. Locked pages cannot be reclaimed, so this trades
                RAM for a guarantee.
            '';
        };
    };

    config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];

        systemd.tmpfiles.rules = [
            "d ${cfg.stateDir} 0775 root ${cfg.group} -"
        ];

        systemd.services.prewarm-warm = {
            description = "Read the pages applications need back into the page cache";
            inherit environment;
            serviceConfig = {
                Type = "oneshot";
                Nice = 19;
                IOSchedulingClass = "idle";
                ExecStart = "${lib.getExe cfg.package} warm";
            };
        };

        systemd.timers.prewarm-warm = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
                OnBootSec = "2min";
                OnUnitActiveSec = cfg.interval;
                AccuracySec = "5min";
            };
        };

        systemd.services.prewarm-lock = lib.mkIf cfg.lock {
            description = "Hold the pages applications need in memory";
            wantedBy = [ "multi-user.target" ];
            after = [ "prewarm-warm.service" ];
            inherit environment;
            unitConfig.ConditionPathExistsGlob = "${cfg.stateDir}/*.pages";
            serviceConfig = {
                Type = "simple";
                Restart = "always";
                RestartSec = 30;
                LimitMEMLOCK = "infinity";
                Nice = 19;
                IOSchedulingClass = "idle";
                ExecStart = "${lib.getExe cfg.package} lock";
            };
        };
    };
}
