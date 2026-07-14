import json
from pathlib import Path

import pytest

from virby_vm_runner.config import VMConfig
from virby_vm_runner.exceptions import VMConfigurationError
from virby_vm_runner.vm_process import VMProcess


def write_config(tmp_path: Path, time_sync: object | None = None) -> Path:
    config: dict[str, object] = {
        "cores": 4,
        "memory": 4096,
        "port": 31222,
        "shared-dirs": {},
        "copy-dirs": {},
    }
    if time_sync is not None:
        config["time-sync"] = time_sync

    path = tmp_path / "config.json"
    path.write_text(json.dumps(config))
    return path


def test_time_sync_is_backward_compatible_when_absent(tmp_path: Path) -> None:
    config = VMConfig(str(write_config(tmp_path)))

    assert config.time_sync_enabled is False
    assert config.time_sync_vsock_port == 1025
    assert "--timesync" not in VMProcess(config, tmp_path).build_vfkit_command()


def test_time_sync_adds_vfkit_command_line(tmp_path: Path) -> None:
    config = VMConfig(
        str(write_config(tmp_path, {"enable": True, "vsock-port": 2345}))
    )

    command = VMProcess(config, tmp_path).build_vfkit_command()
    option_index = command.index("--timesync")

    assert config.time_sync_enabled is True
    assert config.time_sync_vsock_port == 2345
    assert command[option_index + 1] == "vsockPort=2345"
    assert command.count("--timesync") == 1


@pytest.mark.parametrize(
    "time_sync",
    [
        True,
        {"enable": "yes", "vsock-port": 1025},
        {"enable": True, "vsock-port": True},
        {"enable": True, "vsock-port": 1024},
        {"enable": True, "vsock-port": 65536},
    ],
)
def test_invalid_time_sync_configuration_is_rejected(
    tmp_path: Path, time_sync: object
) -> None:
    with pytest.raises(VMConfigurationError):
        VMConfig(str(write_config(tmp_path, time_sync)))
