"""GPU capability probe for the Manga-Colorizer backend.

Verifies that the installed PyTorch build actually has compiled kernels for
this GPU's compute capability -- not merely that a CUDA device is visible.
An RTX 5070 Ti is Blackwell / sm_120; a cu118 or cu126 build will report
is_available()==True and then fail at the first real kernel launch.

Also distinguishes driver-level "no CUDA compute device" (cuInit 100) from
true architecture / wheel mismatch, so the installer does not mislead users.
"""
from __future__ import annotations

import argparse
import sys


def _diagnose_no_cuda() -> str:
    """Best-effort classification when torch.cuda.is_available() is False."""
    reasons: list[str] = []
    try:
        import torch
    except Exception as exc:  # noqa: BLE001
        return f"import_error:{exc}"

    # Probe CUDA without requiring a live device context.
    try:
        count = torch.cuda.device_count()
        reasons.append(f"device_count={count}")
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        reasons.append(f"device_count_exc={msg}")
        if "100" in msg or "no CUDA-capable device" in msg.lower() or "cuda error: unknown error" in msg.lower():
            return "driver_compute:" + ";".join(reasons)

    # Try a raw driver init error string when available.
    try:
        torch.cuda.init()
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        reasons.append(f"cuda_init_exc={msg}")
        low = msg.lower()
        if "100" in msg or "no cuda" in low or "no device" in low or "insufficient" in low:
            return "driver_compute:" + ";".join(reasons)

    if (torch.version.cuda or "") and not torch.cuda.is_available():
        # Wheel has CUDA, OS does not expose a device — almost always driver.
        return "driver_compute:" + ";".join(reasons or ["torch_cuda_build_but_no_device"])

    return "unknown:" + ";".join(reasons or ["cuda_unavailable"])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument(
        "--diagnose",
        action="store_true",
        help="Print a machine-readable failure class and exit non-zero if CUDA is unusable.",
    )
    args = parser.parse_args(argv)

    import torch

    print(f"torch            : {torch.__version__}")
    print(f"torch CUDA build : {torch.version.cuda}")
    print(f"cuda.is_available: {torch.cuda.is_available()}")

    if not torch.cuda.is_available():
        kind = _diagnose_no_cuda()
        print(f"[FAIL] No CUDA device visible to PyTorch ({kind}).")
        if kind.startswith("driver_compute"):
            print(
                "Hint: nvidia-smi can list a GPU while CUDA compute stays dead "
                "(common after a bad/partial driver install). Clean-install the "
                "NVIDIA Game Ready or Studio driver, reboot, then rerun AI9 Setup."
            )
        else:
            print(
                "Hint: if nvidia-smi works but PyTorch still sees no device, "
                "treat this as a driver/CUDA compute problem first — not a "
                "PyTorch architecture mismatch."
            )
        if args.diagnose:
            print(kind)
        return 1

    if args.diagnose:
        print("ok")
        return 0

    idx = torch.cuda.current_device()
    name = torch.cuda.get_device_name(idx)
    major, minor = torch.cuda.get_device_capability(idx)
    arch_list = torch.cuda.get_arch_list()
    total_vram = torch.cuda.get_device_properties(idx).total_memory / (1024 ** 3)

    print(f"device name      : {name}")
    print(f"compute capability: sm_{major}{minor}")
    print(f"total VRAM       : {total_vram:.2f} GiB")
    print(f"compiled archs   : {arch_list}")

    # The decisive check: does this build ship kernels for our arch?
    target = f"sm_{major}{minor}"
    if target not in arch_list:
        print(f"[WARN] {target} not in compiled arch list -- relying on PTX JIT, may fail.")

    # Prove kernels actually launch, rather than trusting is_available().
    try:
        a = torch.randn(4096, 4096, device="cuda")
        b = torch.randn(4096, 4096, device="cuda")
        c = a @ b
        torch.cuda.synchronize()
        print(f"matmul 4096^2    : OK (checksum {c.sum().item():.4f})")
    except Exception as exc:  # noqa: BLE001 - we want the raw failure surfaced
        msg = str(exc)
        print(f"[FAIL] GPU kernel launch failed: {exc}")
        if "no kernel image" in msg.lower() or "compatibility" in msg.lower():
            print("arch_mismatch:kernel_launch")
        return 1

    # Convolution exercises cuDNN, which the colorizer leans on heavily.
    try:
        conv = torch.nn.Conv2d(3, 64, 3, padding=1).cuda()
        x = torch.randn(1, 3, 576, 576, device="cuda")
        with torch.no_grad():
            y = conv(x)
        torch.cuda.synchronize()
        print(f"cudnn conv2d     : OK (out {tuple(y.shape)})")
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] cuDNN conv failed: {exc}")
        return 1

    print("[PASS] GPU inference is functional on this device.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
