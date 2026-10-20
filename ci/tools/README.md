# Infrastructure CI tools

This directory defines the linux/amd64 build root image for the hyperfleet-infra
Prow jobs. The release `images` variant builds it and promotes it to
`registry.ci.openshift.org/ci/hyperfleet-infra-tools` (`latest` and a commit tag).
Its Terraform version is set in the `Dockerfile` and is separate from the local
developer pin in `.tool-versions`.

Every downloaded tool is pinned by version and SHA256 (helm-git by tag and
commit). The base image is pinned by tag and digest. The utility RPMs (git, make,
jq, diffutils, unzip, xz) are not pinned, as in the e2e image.

## Provider mirror

`providers.tf` pins one version of each provider the CI stacks use, and the build
mirrors them into `/usr/local/share/terraform/providers`. `terraformrc` installs
those providers from the mirror and excludes them from the registry, so
`terraform init` does not contact `registry.terraform.io` for them. Init reports
them as `(unauthenticated)`: their signatures were checked when the mirror was
built.

When a stack's provider constraint changes, pick a mirrored version that satisfies
both the old and the new constraint. Add a new provider to `providers.tf` and to
both lists in `terraformrc` before a stack requires it.

## Build and check

```bash
make build-ci-tools   # podman or docker; set CONTAINER_TOOL to choose
make test-ci-tools    # build, then run ci-dry-run and terraform init without network access in the image
```

`test-ci-tools` runs the tracked files, uncommitted edits included, as an
arbitrary UID, like Prow. Add new files with `git add` first. Under qemu
emulation on Apple Silicon the image's Go tools crash (`fatal error:
lfstack.push`), so run the checks on an amd64 host.

## Bumping pins

There is no Renovate configuration for this image, so pins are bumped by hand.

1. Change each version in the `Dockerfile` together with its SHA256. Take the
   checksum from upstream where it is published; ShellCheck publishes none, so
   compute it from the archive. For helm-git, update the tag and the commit it
   points to.
2. For gcloud, take the RPM hashes from Google's
   [repository metadata](https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64/repodata/repomd.xml)
   and check the downloaded RPMs once with `rpm --checksig` after importing
   [Google's key](https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg).
3. Keep kubectl, Helm, Helmfile, helm-git and helm-diff aligned with the
   [e2e Dockerfile](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/Dockerfile).
4. Update `providers.tf` if a stack constraint needs it, then run `make test-ci-tools`.

## Rollback

Point the infra build root in
[openshift/release](https://github.com/openshift/release/tree/main/ci-operator/config/openshift-hyperfleet/hyperfleet-infra)
at a known-good commit tag of `ci/hyperfleet-infra-tools`, and return to `latest`
once a fixed image is promoted. Don't rerun an old promotion postsubmit over a
newer one: it moves `latest` back to the older tools.
