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
