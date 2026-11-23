{ pkgs ?  import <nixpkgs> {}
, firmware ? import ../src {}
}:

let
  config = ./.;

  go60_left = (firmware.zmk.override {
    board = "go60_lh";
    shield = "raw_hid_adapter";
    keymap = "${config}/go60_lh.keymap";
    kconfig = "${config}/go60_lh.conf";
    extraModules = [
      ../modules/zmk-raw-hid
      ../modules/zmk-hid-viz
      ../modules/zmk-input-processor-scroll-inertia
    ];
  }).overrideAttrs (previous: {
    # Upstream ZMK PR 3483. Nix applies this from the app source root.
    patches = (previous.patches or []) ++ [ ./patches/zmk-scroll-resolution.patch ];
  });
  go60_right = firmware.zmk.override { board = "go60_rh"; keymap = "${config}/go60.keymap"; kconfig = "${config}/go60_rh.conf"; };

in firmware.combine_uf2 go60_left go60_right "go60"
