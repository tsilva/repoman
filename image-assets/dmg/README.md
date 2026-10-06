# RepoMan DMG design

`Tools/package-dmg.sh` includes the background and saved Finder layout in every
installer. The 720 × 480 point window has a pale cool-gray background, faint blue
icon panels, restrained charcoal typography, and a thin muted installation arrow.

- `background.png`: 720 × 480 preview and standard-resolution artwork.
- `background.tiff`: combined 720 × 480 and 1440 × 960 representations for Retina
  displays, produced with macOS `tiffutil -cathidpicheck`.
- `finder-layout.DSStore`: saved Finder settings copied into the volume as
  `.DS_Store`; icon view, no toolbar/sidebar/status bar, 96-point icons, 13-point
  labels, no automatic sorting, and no scrolling.
- `../sources/dmg-background-source.png`: original generated artwork.
- `../sources/dmg-background-prompt.txt`: exact built-in image-generation prompt.

The app icon is centered at (204, 238) and Applications at (515, 238). Finder
renders the real app icon, folder icon, and their labels over the empty panels.
The app extension is hidden with `SetFile -a E`. The `.background` directory and
`.DS_Store` remain hidden in normal Finder use.

The layout uses a portable legacy alias to
`/.background/background.tiff` relative to the **RepoMan** HFS+ volume. Keep the
volume name and background path in sync with the packaging script. The alias
contains no developer home-directory or temporary build path. Packaging needs
no Finder automation or third-party Python packages on release runners.

The initial layout was created using `ds-store==1.3.2` and `mac-alias==2.2.2` in
an ignored build directory. If changing the layout, use those tools or Finder
to regenerate the saved settings, preserve the volume-relative background
alias, and verify the result on a freshly mounted image. The
[dmgbuild implementation](https://github.com/dmgbuild/dmgbuild/blob/main/src/dmgbuild/core.py)
documents the Finder settings and alias fields used here.

For a packaging preview, use an existing development app bundle with
`Tools/package-dmg.sh` and save the resulting DMG under `.build/`. Check the app,
Applications symlink, hidden background, window size, and icon locations in the
mounted image. A design preview does not constitute a release build or
publication; use the project's release skill for release work.
