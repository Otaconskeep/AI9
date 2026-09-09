"""GPU capability probe for the Manga-Colorizer backend.

Verifies that the installed PyTorch build actually has compiled kernels for
this GPU's compute capability -- not merely that a CUDA device is visible.
An RTX 5070 Ti is Blackwell / sm_120; a cu118 or cu126 build will report
is_available()==True and then fail at the first real kernel launch.
"""
import sys

import torch


def main() -> int:
    print(f"torch            : {torch.__version__}")
    print(f"torch CUDA build : {torch.version.cuda}")
    print(f"cuda.is_available: {torch.cuda.is_available()}")

    if not torch.cuda.is_available():
        print("[FAIL] No CUDA device visible to PyTorch.")
        return 1

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
        print(f"[FAIL] GPU kernel launch failed: {exc}")
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
