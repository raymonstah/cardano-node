{ system ? builtins.currentSystem
, crossSystem ? null
, config ? {}
, customConfig ? {}
, sourcesOverride ? {}
, gitrev ? null
}:
let
  flakeSources = let
    flakeLock = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes;
    compat = s: builtins.fetchGit {
      url = "https://github.com/${s.locked.owner}/${s.locked.repo}.git";
      inherit (s.locked) rev;
      ref = s.original.ref or "master";
    };
  in {
    "haskell.nix" = compat flakeLock.haskellNix;
    "iohk-nix" = compat flakeLock.iohkNix;
    "plutus-example" = compat flakeLock.plutus-example;
  };
  sources = flakeSources // sourcesOverride;
  haskellNix = import sources."haskell.nix" { inherit system sourcesOverride; };
  # IMPORTANT: report any change to nixpkgs channel in flake.nix:
  nixpkgs = haskellNix.sources.nixpkgs-2105;
  iohkNix = import sources.iohk-nix { inherit system; };
  # for inclusion in pkgs:
  overlays =
    # Haskell.nix (https://github.com/input-output-hk/haskell.nix)
    haskellNix.nixpkgsArgs.overlays
    # haskell-nix.haskellLib.extra: some useful extra utility functions for haskell.nix
    ++ iohkNix.overlays.haskell-nix-extra
    ++ iohkNix.overlays.crypto
    # iohkNix: nix utilities:
    ++ iohkNix.overlays.iohkNix
    ++ iohkNix.overlays.utils
    # our own overlays:
    ++ [
      (pkgs: _: {
        gitrev = if gitrev == null
          then iohkNix.commitIdFromGitRepoOrZero ../.git
          else gitrev;
        customConfig = pkgs.lib.recursiveUpdate
          (import ./custom-config.nix pkgs.customConfig)
          customConfig;
        inherit (pkgs.iohkNix) cardanoLib;
        # commonLib: mix pkgs.lib with iohk-nix utils and our own:
        commonLib = with pkgs; lib // cardanoLib // iohk-nix.lib
          // import ./util.nix { inherit haskell-nix; }
          // import ./svclib.nix { inherit pkgs; }
          # also expose our sources, nixpkgs and overlays
          // { inherit overlays sources nixpkgs; };
        inherit ((import sources.plutus-example {
          inherit system;
          gitrev = sources.plutus-example.rev;
        }).haskellPackages.plutus-example.components.exes) plutus-example;

        # This provides a supervisord-backed instance of a the workbench development environment
        # that can be used with nix-shell or lorri.
        # See https://input-output-hk.github.io/haskell.nix/user-guide/development/
        workbench-supervisord =
          { useCabalRun, profileName, haskellPackages }:
          pkgs.callPackage ./supervisord-cluster
            { inherit profileName useCabalRun haskellPackages;
              workbench = pkgs.callPackage ./workbench { inherit useCabalRun; };
            };
      })
      # And, of course, our haskell-nix-ified cabal project:
      (import ./pkgs.nix)
    ];

  pkgs = import nixpkgs {
    inherit system crossSystem overlays;
    config = haskellNix.nixpkgsArgs.config // config;
  };

in pkgs
