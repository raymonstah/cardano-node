{ lib
, stdenv
, pkgs
, git
, graphviz
, jq
, moreutils
, makeWrapper
, runCommand
, customConfig
, cardano-cli
, cardano-topology
, locli

, useCabalRun
}:

with lib; with customConfig.localCluster;

let
  nixWbMode =
    if useCabalRun
    then "cabal-exes+nix-wb"
    else "nix-exes+nix-wb";

  workbench' = tools:
    stdenv.mkDerivation {
      pname = "workbench";

      version = "0.1";

      src = ./.;

      buildInputs = [ jq makeWrapper ];

      buildPhase = ''
        patchShebangs .
      '';

      postFixup = ''
        wrapProgram "$out/bin/wb" --argv0 wb --add-flags "--set-mode ${nixWbMode}" \
        --prefix PATH ":" ${pkgs.lib.makeBinPath tools}
      '';

      installPhase = ''
        mkdir -p         $out/bin
        cp -a wb profiles *.sh *.jq $out/bin
      '';

      dontStrip = true;
    };

  workbench = workbench'
    [ git graphviz
      jq
      moreutils

      cardano-cli
      cardano-topology
      locli
    ];

  runWorkbench =
    name: command:
    runCommand name {} ''
      ${workbench}/bin/wb ${command} > $out
    '';

  runWorkbenchJqOnly =
    name: command:
    runCommand name {} ''
      ${workbench' [jq moreutils]}/bin/wb ${command} > $out
    '';

  runJq =
    name: args: query:
    runCommand name {} ''
      args=(${args})
      ${jq}/bin/jq '${query}' "''${args[@]}" > $out
    '';

  exeCabalOp = op: exe:
    toString [ "cabal" "-v0" op "--" "exe:${exe}"];

  checkoutWbMode =
    if useCabalRun
    then "cabal-exes+checkout-wb"
    else "nix-exes+checkout-wb";

  shellHook = ''
    echo 'workbench shellHook:  workbenchDevMode=${toString workbenchDevMode} useCabalRun=${toString useCabalRun}'
    export WORKBENCH_BACKEND=supervisor

    ${optionalString
      workbenchDevMode
    ''
    export WORKBENCH_CARDANO_NODE_REPO_ROOT=$(git rev-parse --show-toplevel)
    export WORKBENCH_EXTRA_FLAGS=

    function wb() {
      $WORKBENCH_CARDANO_NODE_REPO_ROOT/nix/workbench/wb --set-mode ${checkoutWbMode} $WORKBENCH_EXTRA_FLAGS "$@"
    }
    export -f wb
    ''}

    ${optionalString
      useCabalRun
      ''
      . nix/workbench/lib.sh
      . nix/workbench/lib-cabal.sh
      ''}

    export CARDANO_NODE_SOCKET_PATH=run/current/node-0/node.socket
    '';

  generateProfiles =
    { pkgs

    ## The backend is an attrset of AWS/supervisord-specific methods and parameters.
    , backend

    ## Environment arguments:
    ##   - either affect semantics on all backends equally,
    ##   - or have no semantic effect
    , envArgs
    }:
    rec {
      profile-names-json =
        runWorkbenchJqOnly "profile-names.json" "profiles list";

      profile-names =
        __fromJSON (__readFile profile-names-json);

      environment =
        ## IMPORTANT:  keep in sync with envArgs in 'supervisord-cluster/default.nix/envArgs'.
        with envArgs; rec {
          inherit cardanoLib stateDir;

          JSON = runWorkbenchJqOnly "environment.json"
          ''env compute-config \
            --cache-dir "${cacheDir}" \
            --base-port ${toString basePort} \
            ${optionalString staggerPorts "--stagger-ports"} \
          '';
          value = __fromJSON (__readFile JSON);
        };

      mkProfile =
        profileName:
        pkgs.callPackage ./profiles
          { inherit
              pkgs
              runWorkbenchJqOnly runJq workbench
              backend
              environment
              profileName;
          };

      profiles = genAttrs profile-names mkProfile;

      profilesJSON =
        runWorkbenchJqOnly "all-profiles.json" "profiles generate-all";
    };

  ## ## This allows forwarding of Nix-expressed computation results to bash-land.
  profileOutput =
    { profile
    , backendProfileOutput ## Backend-specific results for forwarding
    }:
    runCommand "workbench-profile-outputs-${profile.name}"
      { buildInputs = [];
        nodeServices =
          __toJSON
          (flip mapAttrs profile.node-services
            (name: svc:
              with svc;
              { inherit name;
                service-config = serviceConfig.JSON;
                start          = startupScript;
                config         = nodeConfig.JSON;
                topology       = topology.JSON;
              }));
        generatorService =
          with profile.generator-service;
          __toJSON
          { name           = "generator";
            service-config = serviceConfig.JSON;
            start          = startupScript;
            run-script     = runScript.JSON;
          };
        passAsFile = [ "nodeServices" "generatorService" ];
      }
      ''
      mkdir $out
      cp    ${backendProfileOutput}/*  $out
      cp    $nodeServicesPath          $out/node-services.json
      cp    $generatorServicePath      $out/generator-service.json
      '';

  with-workbench-profile =
    { pkgs, backend, envArgs, profileName }:
    let
      workbenchProfiles = generateProfiles
        { inherit pkgs backend envArgs; };

      profile = workbenchProfiles.profiles."${profileName}"
        or (throw "No such profile: ${profileName};  Known profiles: ${toString (__attrNames workbenchProfiles.profiles)}");

      profileOut = profileOutput
        { inherit profile;
          backendProfileOutput =
            backend.profileOutput { inherit profile; };
        };
    in { inherit profile profileOut; };

  run-analysis =
    { pkgs, run }:
    let profile = { name = "stub"; }; #__fromJSON (__readFile "${run}/profile.json");
    in
    pkgs.runCommand "workbench-run-analysis-${profile.name}"
      { requiredSystemFeatures = [ "benchmark" ];
        nativeBuildInputs = with haskellPackages; with pkgs; [
          bash
          bech32
          coreutils
          gnused
          jq
          moreutils
          nixWrapped
          psmisc
          python3Packages.supervisor
          workbench
        ];
      }
      ''
      echo "analysing run:  ${run}"
      mkdir -p $out

      ln -s ${run} $out/run

      args=(
          analyse
          --filters size-full
          --outdir  $out
          standard
          ${run}
           )
      echo "wb ''${args[*]}" > $out/wb-invocation.sh

      wb ''${args[@]}
      '';
in

{
  inherit workbench runWorkbench runJq with-workbench-profile run-analysis;

  inherit generateProfiles profileOutput shellHook;
}
