{
  description = "ZMK firmware: Lily58 + Sofle on nice!nano v2";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      # Готовые бинарники Arm после patchelf падают в ld.so (glibc 2.44): новый
      # RW-сегмент патчелфа делит страницу с R-сегментом, .dynamic оказывается
      # read-only, а ld.so пишет туда r_debug через DT_DEBUG. Меняем DT_DEBUG на
      # игнорируемый DT_CHECKSUM — писать в .dynamic больше некуда.
      armGcc = pkgs.runCommand "${pkgs.gcc-arm-embedded.name}-nodtdebug"
        { nativeBuildInputs = [ pkgs.python3 ]; } ''
        cp -r --no-preserve=mode ${pkgs.gcc-arm-embedded} $out
        find ${pkgs.gcc-arm-embedded} -type f -perm -u+x -printf '%P\0' \
          | (cd $out && xargs -0 chmod +x)
        find $out -type f -perm -u+x -print0 | xargs -0 python3 ${pkgs.writeText "undebug.py" ''
          import struct, sys

          for path in sys.argv[1:]:
              with open(path, "r+b") as f:
                  d = f.read()
                  if d[:4] != b"\x7fELF" or d[4] != 2:
                      continue
                  phoff, = struct.unpack_from("<Q", d, 0x20)
                  phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
                  for i in range(phnum):
                      p_type, _, p_offset, _, _, p_filesz = struct.unpack_from("<IIQQQQ", d, phoff + i * phentsize)
                      if p_type != 2:  # PT_DYNAMIC
                          continue
                      for off in range(p_offset, p_offset + p_filesz, 16):
                          tag, = struct.unpack_from("<q", d, off)
                          if tag == 0:
                              break
                          if tag == 21:  # DT_DEBUG -> DT_CHECKSUM
                              f.seek(off)
                              f.write(struct.pack("<q", 0x6ffffdf8))
        ''}
        $out/bin/arm-none-eabi-gcc --version
      '';

      pythonEnv = pkgs.python3.withPackages (ps: with ps; [
        west
        pyelftools
        pyyaml
        pykwalify
        packaging
        setuptools
        canopen
        anytree
        intelhex
        protobuf
        grpcio-tools
      ]);

      # setuptools >= 81 больше не тащит pkg_resources, а генератору nanopb
      # нужен только resource_filename('grpc_tools', '_proto').
      pyshim = pkgs.writeTextDir "pkg_resources.py" ''
        import importlib.util
        import os


        def resource_filename(package_or_requirement, resource_name):
            spec = importlib.util.find_spec(package_or_requirement)
            if spec is None or spec.origin is None:
                raise ModuleNotFoundError(package_or_requirement)
            return os.path.join(os.path.dirname(spec.origin), resource_name)


        def resource_string(package_or_requirement, resource_name):
            with open(resource_filename(package_or_requirement, resource_name), "rb") as f:
                return f.read()
      '';

      tools = [
        pythonEnv
        pkgs.cmake
        pkgs.ninja
        pkgs.dtc
        pkgs.gperf
        armGcc
        pkgs.protobuf
        pkgs.git
        pkgs.coreutils
        pkgs.gnused
        pkgs.findutils
      ];

      env = ''
        export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
        export GNUARMEMB_TOOLCHAIN_PATH=${armGcc}
        export PYTHONPATH=${pyshim}''${PYTHONPATH:+:$PYTHONPATH}
      '';

      # Те же цели, что в build.yaml для GitHub Actions.
      targets = {
        lily58_left = { snippet = "studio-rpc-usb-uart"; cmakeArgs = "-DCONFIG_ZMK_STUDIO=y"; };
        lily58_right = { };
        sofle_left = { snippet = "studio-rpc-usb-uart"; cmakeArgs = "-DCONFIG_ZMK_STUDIO=y"; };
        sofle_right = { };
        settings_reset = { };
      };

      targetCase = lib.concatStrings (lib.mapAttrsToList (shield: t: ''
        ${shield}) snippet=${lib.escapeShellArg (t.snippet or "")}; extra=${lib.escapeShellArg (t.cmakeArgs or "")} ;;
      '') targets);

      # Сборка грязная (west качает модули в .zmk/), поэтому это скрипт для
      # `nix run`, а не derivation. Прошивки складываются в firmware/.
      zmk-build = pkgs.writeShellApplication {
        name = "zmk-build";
        runtimeInputs = tools;
        text = ''
          ${env}
          root=$(git rev-parse --show-toplevel)
          ws=$root/.zmk
          cd "$ws" 2>/dev/null || { mkdir -p "$ws"; cd "$ws"; }

          if [ ! -d .west ]; then
            mkdir -p config
            ln -sfn "$root/config/west.yml" config/west.yml
            python3 -m west init -l config
            python3 -m west update
          elif [ "''${ZMK_UPDATE:-0}" = 1 ]; then
            python3 -m west update
          fi

          # `west` из nixpkgs — враппер, который подсовывает в PATH голый python3,
          # а старый shellHook прибивал шебанги nanopb к путям в store, которые
          # потом удаляет GC. Возвращаем env, чтобы брался python из PATH.
          find modules/lib/nanopb/generator build/*/nanopb/generator \
            -maxdepth 1 \( -name protoc -o -name protoc-gen-nanopb \) \
            -exec sed -i '1s|^#!.*|#!/usr/bin/env python3|' {} + 2>/dev/null || true

          if [ $# -eq 0 ]; then
            echo "usage: zmk-build <shield>... (${lib.concatStringsSep ", " (lib.attrNames targets)})" >&2
            exit 1
          fi

          mkdir -p "$root/firmware"
          for shield in "$@"; do
            case $shield in
              ${targetCase}
              *) echo "unknown shield: $shield" >&2; exit 1 ;;
            esac

            snippet_args=()
            if [ -n "$snippet" ]; then snippet_args=(-S "$snippet"); fi
            extra_args=()
            if [ -n "$extra" ]; then read -ra extra_args <<<"$extra"; fi

            # CMake кэширует путь к тулчейну и snippet: после обновления nixpkgs
            # или смены параметров старая папка сборки только мешает.
            stamp="$GNUARMEMB_TOOLCHAIN_PATH $snippet $extra"
            if [ "$(cat "build/$shield/.flake-stamp" 2>/dev/null)" != "$stamp" ]; then
              rm -rf "build/$shield"
            fi

            echo "==> $shield"
            python3 -m west build ''${ZMK_PRISTINE:+-p} -s zmk/app -d "build/$shield" -b nice_nano_v2 \
              "''${snippet_args[@]}" -- \
              -DSHIELD="$shield" -DZMK_CONFIG="$root/config" \
              "''${extra_args[@]}"
            echo "$stamp" > "build/$shield/.flake-stamp"
            cp "build/$shield/zephyr/zmk.uf2" "$root/firmware/$shield.uf2"
            echo "==> firmware/$shield.uf2"
          done
        '';
      };

      app = args: {
        type = "app";
        program = toString (pkgs.writeShellScript "zmk-build-${lib.concatStringsSep "-" args}" ''
          exec ${zmk-build}/bin/zmk-build ${lib.escapeShellArgs args} "$@"
        '');
      };
    in
    {
      packages.${system}.default = zmk-build;

      apps.${system} = {
        default = app [ "lily58_left" "lily58_right" ];
        left = app [ "lily58_left" ];
        right = app [ "lily58_right" ];
        sofle = app [ "sofle_left" "sofle_right" ];
        reset = app [ "settings_reset" ];
        build = app [ ];
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = tools ++ [ zmk-build ];
        shellHook = env;
      };
    };
}
