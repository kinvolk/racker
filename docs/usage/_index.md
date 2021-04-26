---
content_type: racker
title: Using Racker
weight: 50
---

Racker is used through the command `racker`. This section shows how to use it and interact with Lokomotive Kubernetes or Flatcar Container Linux.

Both Lokomotive and Flatcar Container Linux follow the principle of _Immutable Infrastructure_ and rely on reprovisioning of the OS to apply configuration changes.
Lokomotive integrates the provisioning of Flatcar Container Linux with the provisioning of Kubernetes into a single action.

Lokomotive uses the declarative configuration tool `lokoctl` while the plain Flatcar Container Linux deployment
uses the declarative configuration tool `terraform`.
Both use the Container Linux Config format to define the OS configuration.
Read more about the technologies in the Flatcar Container Linux [docs](https://kinvolk.io/docs/flatcar-container-linux/latest/provisioning/).
