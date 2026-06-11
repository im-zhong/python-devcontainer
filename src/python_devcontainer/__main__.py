"""Run with `uv run python-devcontainer` or `python -m python_devcontainer`."""

from pdc_core import greet


def main() -> None:
    print(greet("python-devcontainer"))


if __name__ == "__main__":
    main()
