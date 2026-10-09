# =============================================================================
# Graphics / QuickSync — contract §4
#
# The only job of the GPU stack on this machine is hardware video transcoding
# through the Intel Iris Xe iGPU in the i7-12700H. There is no display server,
# no desktop, no OpenGL application. `hardware.graphics.enable` here really
# means "install a working VAAPI userspace", not "run a desktop".
# =============================================================================
{ pkgs, ... }:

{
  hardware.graphics = {
    enable = true;

    # NOTE ON THE OPTION NAME: this was `hardware.opengl.*` until 24.11, when it
    # was renamed to `hardware.graphics.*`. In 26.05 the old name is fully gone
    # — not even a deprecation alias remains — so any guide or LLM output using
    # `hardware.opengl` against this release will fail to evaluate. Verified
    # against nixos/modules/hardware/graphics.nix in the pinned nixpkgs.
    #
    # `enable32Bit` is deliberately NOT set. It exists for 32-bit games and
    # Wine. Nothing here is 32-bit, and enabling it roughly doubles the size of
    # the graphics closure for no benefit.

    extraPackages = with pkgs; [
      # --- The VAAPI driver -------------------------------------------------
      # iHD, the modern Intel driver. Contract §4 requires this and explicitly
      # rules out the legacy i965 driver.
      #
      # For the record, in 26.05 the legacy driver is not merely discouraged,
      # it is unavailable under the name most guides use: `vaapiIntel` does not
      # exist as an attribute at all. It survives as `intel-vaapi-driver`, which
      # tops out around Gen9 hardware and would not properly drive Alder Lake
      # even if the contract permitted it.
      intel-media-driver

      # --- The oneVPL / QuickSync runtime -----------------------------------
      # This is the package prompt 1 warned had churned through three names, so
      # I resolved it against the pinned release rather than from memory. In
      # nixos-26.05:
      #
      #   intel-media-sdk    exists, but is the LEGACY MSDK, stuck at 23.2.2.
      #                      Superseded; wrong choice for Alder Lake.
      #   onevpl-intel-gpu   DOES NOT EXIST. The attribute is gone.
      #   vpl-gpu-rt         EXISTS, version 26.1.6.  <-- this one
      #
      # The clincher is the version number: vpl-gpu-rt is 26.1.6 and
      # intel-media-driver is also 26.1.6 — they are two halves of the same
      # upstream Intel release, meant to be deployed together.
      vpl-gpu-rt
    ];
  };

  # ---------------------------------------------------------------------------
  # Make the kernel bind i915 to the iGPU, not xe — the prerequisite for all of
  # the above
  # ---------------------------------------------------------------------------
  # Everything else in this module configures the VAAPI USERSPACE. None of it
  # matters if no kernel DRM driver binds the Intel iGPU and creates
  # /dev/dri/renderD128 — and on the kernel this release ships (6.18), by
  # default NOTHING does.
  #
  # The new `xe` driver now claims Alder Lake-P (PCI 8086:46a6) but then refuses
  # it — "Your graphics device 46a6 is not officially supported by xe driver in
  # this kernel version" — and never binds (lsmod shows xe loaded with 0 refs).
  # Because xe has reserved the ID, i915 (which fully supports this GPU and is
  # the driver the iHD stack above expects) is kept off it and never loads. The
  # result: the only /dev/dri node is card0, a simpledrm EFI framebuffer; there
  # is no render node; and every VAAPI transcode dies with "Device creation
  # failed / No device available for decoder: vaapi", which surfaces in Jellyfin
  # clients as a "source error" the moment a transcode (e.g. a downscale to
  # 360p) is required. Confirmed on hardware 2026-09-07.
  #
  # Steer the arbitration explicitly: force i915 onto 46a6 and keep xe off it.
  # The kernel's own diagnostic prints the inverse pair (to force xe); this is
  # that pair flipped, because on Alder Lake i915 is the mature, supported path.
  # Takes effect on reboot; verify with `ls /dev/dri` (expect renderD128) and
  # `vainfo` (expect H264/HEVC encode+decode).
  #
  # If low-power encode later needs GuC/HuC (the VERIFY note at the bottom of
  # this file), add "i915.enable_guc=3" to THIS same list, not a second
  # boot.kernelParams.
  boot.kernelParams = [
    "i915.force_probe=46a6"
    "xe.force_probe=!46a6"
  ];

  # ---------------------------------------------------------------------------
  # Tell libva which driver to load
  # ---------------------------------------------------------------------------
  # Strictly speaking this is belt-and-braces: iHD is the only driver installed,
  # so libva's autodetection would land on it anyway. It is set explicitly so
  # that if someone later adds intel-vaapi-driver for some reason, the host does
  # not silently start using the legacy driver.
  #
  # This affects the HOST only — it is what makes `vainfo` over SSH meaningful.
  # The Jellyfin container has its own environment; setting a driver name for it
  # is the stack repo's job, not this one's.
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # ---------------------------------------------------------------------------
  # Tools to prove it actually works
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    # `vainfo` — enumerates the VAAPI profiles the driver exposes. This is the
    # contract §7 check. On a working Alder Lake box expect H264 and HEVC encode
    # + decode, HEVC Main10, VP9 decode, AV1 decode.
    # Note the package is `libva-utils`; there is no package called `vainfo`.
    libva-utils

    # `intel_gpu_top` — live per-engine utilisation. This is how you tell a real
    # hardware transcode from a silent fallback to software: you want activity
    # on the Video / VideoEnhance engines, not just the CPU cores.
    intel-gpu-tools
  ];

  # VERIFY: low-power encoding needs GuC/HuC firmware loaded by i915.
  #   Jellyfin's "Intel Low-Power H.264/HEVC encoder" toggle depends on HuC
  #   being authenticated. Recent kernels default to enabling GuC submission +
  #   HuC on Gen12+ (which Alder Lake is), so this most likely needs no config
  #   at all — but I could not confirm the default for the exact kernel this
  #   release ships, and I would rather flag it than assert it.
  #
  #   Check on the real machine:
  #       sudo dmesg | grep -iE 'i915.*(guc|huc)'
  #   You want HuC reported as authenticated / running.
  #
  #   If it is NOT loaded, the fix is one line in this file:
  #       boot.kernelParams = [ "i915.enable_guc=3" ];
  #   Do not add that pre-emptively — forcing it on a kernel that already does
  #   the right thing is how you end up debugging a GPU hang instead.
}
