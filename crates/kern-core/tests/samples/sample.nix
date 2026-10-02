# A package
{ lib, stdenv, fetchurl, enable ? true }:

let
  version = "1.2";
  src = ./src;
in
stdenv.mkDerivation rec {
  pname = "kern";
  inherit version src;
  doCheck = if enable then false else null;
  buildPhase = ''
    make -j$NIX_BUILD_CORES PREFIX=${placeholder "out"}
    echo "done" > log
  '';
  meta.homepage = https://kern.dev;
  check = /* bash */ ''
    test -x $out/bin/kern
  '';
  passthru.tests = builtins.map (x: x + 1) [ 1 2 ];
}
