{ pkgs ?  import <nixpkgs> {}
, firmware ? import ../src {}
}:

let
  config = ./.;
  hidVizModules = [
    ../modules/zmk-raw-hid
    ../modules/zmk-hid-viz
  ];

  go60_left  = firmware.zmk.override {
    board = "go60_lh";
    shield = "raw_hid_adapter";
    keymap = "${config}/go60.keymap";
    kconfig = "${config}/go60_lh.conf";
    extraModules = hidVizModules;
  };
  go60_right = firmware.zmk.override { board = "go60_rh"; keymap = "${config}/go60.keymap"; kconfig = "${config}/go60_rh.conf"; };

in firmware.combine_uf2 go60_left go60_right "go60"
