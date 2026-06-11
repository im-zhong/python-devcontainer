from pdc_core import greet


def test_greet_basic() -> None:
    assert greet("world") == "Hello from world!"
