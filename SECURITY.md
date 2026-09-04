# Security

RustMCP Harbor intentionally does not bake credentials or MCPX configuration into the image.

For deployments:

- keep `/config` on a private dataset;
- use tunnel-client `env:` or `file:` secret references instead of literal API keys in checked-in files;
- run the container unprivileged;
- do not mount the Docker socket or host `/dev`;
- do not expose MCPX or tunnel health ports unless you have a specific local-network requirement;
- use restricted tunnel runtime credentials for long-lived tunnel processes.
