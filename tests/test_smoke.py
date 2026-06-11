from python_devcontainer import __version__


def test_version_string() -> None:
    assert isinstance(__version__, str)
    assert __version__  # non-empty
