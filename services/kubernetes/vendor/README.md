# Pinned Upstream Charts

These unmodified public archives are the exact inputs verified in PR #31.
Vendoring lets an authorized OpenTofu plan build the native RKE2 HelmChart objects
without a separate download/enrollment file or an install-time release fetch.
They contain no deployment configuration or secret values.

| Archive | Source | SHA-256 |
| --- | --- | --- |
| `secrets-store-csi-driver-1.6.2.tgz` | [CSI chart][csi] | `2658657164b156c7759772a84ba83013ae2495a0b2d2e92ea6b2ad0738f623c4` |
| `openbao-0.30.7.tgz` | [OpenBao chart][bao] | `fa4e6f3c1bbe936dc7ba079f1303ea56810af2f8600f046d8d5809860a4f980f` |

The corresponding upstream licenses are included alongside the archives. Update
source/version/checksum, image digests, native blueprint and render tests together.
Archive checksums bind publisher-provided bytes, not an independent signature.

[csi]: https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts/secrets-store-csi-driver-1.6.2.tgz
[bao]: https://github.com/openbao/openbao-helm/releases/download/openbao-0.30.7/openbao-0.30.7.tgz
