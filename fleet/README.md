# Fleet pointers

A fleet pointer is the teknoir-demo-gitops commit that the DeviceApplicationSets (DAS) of one hardware class
send to the robots of that class. It lives in `fleet/<class>.yaml`, one small file per class, so moving a class
to new robot content is one small gitops PR.

## Flow: a class moves to new content

1. A PR to [teknoir-demo-gitops](https://github.com/teknoir/teknoir-demo-gitops) lands and gives commit `F`.
   A push to that repo alone reaches no device: every application item names a commit.
2. A gitops PR sets `revision: F` in `fleet/<class>.yaml`.
3. Kargo promotes and verifies that commit like any other gitops change: the class DAS then send `F`.

## The class of a robot

The class of a robot is the label `teknoir.org/hw-class` on its Robot in
`charts/device-controller/values.yaml` (`platformRobots`); the values are `jetson-orin`, `nvidia-rtx` and
`raspberry-pi`. device-controller copies the Robot's labels onto its Device, and the class DAS select on that
label (`teknoir.org/hw-class: <class>`).

## Adding a class

1. A new `fleet/<class>.yaml` with `fleets.<class>.revision`.
2. A `valueFiles` line for `../../fleet/<class>.yaml` in the device-controller Application
   (`charts/app-of-apps/templates/controllers.yaml`).
3. A DAS entry with `fleet: <class>` and a selector on `teknoir.org/hw-class: <class>`
   (`charts/device-controller/values.yaml`).

`scripts/check-pins.py` checks the pointers: one class per file, named after the file, and a 40-hex commit.
