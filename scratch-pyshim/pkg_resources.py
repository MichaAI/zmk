"""Minimal pkg_resources shim.

Modern setuptools (>=81) no longer bundles pkg_resources, but nanopb's
generator only needs resource_filename('grpc_tools', '_proto'). Provide just
enough of the API to satisfy that call.
"""
import importlib.util
import os


def resource_filename(package_or_requirement, resource_name):
    spec = importlib.util.find_spec(package_or_requirement)
    if spec is None or spec.origin is None:
        raise ModuleNotFoundError(package_or_requirement)
    base = os.path.dirname(spec.origin)
    return os.path.join(base, resource_name)


def resource_string(package_or_requirement, resource_name):
    with open(resource_filename(package_or_requirement, resource_name), "rb") as f:
        return f.read()
