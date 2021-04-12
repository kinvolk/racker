---
title: Troubleshooting
weight: 100
---

This section has a list of Frequently Asked Questions related to issues when installing/using `racker`.

If you run into problems using `racker`, please file an issue [here](https://github.com/kinvolk/racker/issues).


### Racker's installation seems to be corrupt (e.g. the racker command doesn't work). How can one clean up the installation & reinstall racker?

Remove the `/opt/racker` folder and [reinstall racker](../_index.md).

Depending on Racker's version and evolution, maybe some broken symbolic links will be left. To remove any dangling sym links from `/opt/bin` you can do e.g. (notice that this example command will delete **any** broken links, related to racker or not):
`sudo find /opt/bin/ -type l ! -exec test -e {} \; -delete`

### Racker's been upgraded by mistake when it was intended to be updated. How can one go back to the previous version?

If you know the version that was deployed before upgrade, then you can use the `racker get` command for installing the needed version, e.g. `racker get 0.6` will install version 0.6. After this step, any calls to `racker update` will safely update to a compatible version.

### There is a node that keeps failing. How can we ignore that node when provisioning a cluster?

Please refer to the `bootstrap` command's option [`-exclude` instructions](../usage/bootstrap.md).

## Have more questions?

If you have more questions/suggestions about issues that are so common that they should be listed above, please [file an issue](https://github.com/kinvolk/racker/issues) about them.
