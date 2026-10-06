let
  pkgs = import <nixpkgs> { };
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    west
    pyelftools
    pyyaml
    pykwalify
    packaging
    setuptools
    pip
    canopen
    anytree
    intelhex
    protobuf
    grpcio-tools
  ]);
in
pkgs.mkShell {
  packages = [
    pythonEnv
    pkgs.cmake
    pkgs.ninja
    pkgs.dtc
    pkgs.gperf
    pkgs.gcc-arm-embedded
    pkgs.protobuf
    pkgs.git
    pkgs.wget
  ];
  shellHook = ''
    export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
    export GNUARMEMB_TOOLCHAIN_PATH=${pkgs.gcc-arm-embedded}
    export PYTHONPATH=/home/MichaAI/zmk/scratch-pyshim:$PYTHONPATH

    # `west` из nixpkgs — wrapper, который на старте ставит в начало PATH голый
    # python3 без пакетов. Из-за этого `#!/usr/bin/env python3` в скриптах nanopb
    # внутри `west build` теряет protobuf/grpcio-tools. Прибиваем шебанги к python
    # этого шелла — заново на каждый вход, чтобы путь не протухал после обновления
    # канала или nix-collect-garbage.
    for f in /home/MichaAI/zmk/.zmk/modules/lib/nanopb/generator/protoc \
             /home/MichaAI/zmk/.zmk/modules/lib/nanopb/generator/protoc-gen-nanopb \
             /home/MichaAI/zmk/.zmk/build/*/nanopb/generator/protoc \
             /home/MichaAI/zmk/.zmk/build/*/nanopb/generator/protoc-gen-nanopb; do
      if [ -f "$f" ]; then
        sed -i "1s|^#!.*|#!${pythonEnv}/bin/python3|" "$f"
      fi
    done
  '';
}
