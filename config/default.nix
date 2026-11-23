{ pkgs ?  import <nixpkgs> {}
, firmware ? import ../src {}
, leftOnly ? false
}:

let
  config = ./.;

  go60_left = firmware.zmk.override {
    board = "go60_lh";
    shield = "raw_hid_adapter";
    keymap = "${config}/go60_lh.keymap";
    kconfig = "${config}/go60_lh.conf";
    extraModules = [
      ../modules/zmk-raw-hid
      ../modules/zmk-hid-viz
      ../modules/zmk-input-processor-scroll-inertia
    ];
  };
  go60_right = firmware.zmk.override { board = "go60_rh"; keymap = "${config}/go60.keymap"; kconfig = "${config}/go60_rh.conf"; };

in if leftOnly then go60_left else (firmware.combine_uf2 go60_left go60_right "go60").overrideAttrs (old: {
  buildCommand = old.buildCommand + ''
    ln -s ${go60_left} $out/lh
    ln -s ${go60_right} $out/rh
  '';
})
