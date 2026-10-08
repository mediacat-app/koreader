# MediaCat

MediaCat puts a simple OPDS login and catalog browser over KOReader's FileManager screen. It uses KOReader's built-in OPDS browser modules and download dialog. Catalog feeds with no child catalogs are shown as a cover grid when their OPDS entries include images.

This is an early prototype. It covers the FileManager home screen; it does not change KOReader's startup choice when KOReader opens a previously open book directly.

## Install on a device

1. Copy the whole `opds_home.koplugin` folder into the device's `koreader/plugins/` folder.
   - Kobo: `/.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/` on the Kindle storage volume
   - Android: `koreader/plugins/` in KOReader's data folder
   - PocketBook: `/applications/koreader/plugins/`
2. Eject the device and restart KOReader.
3. Open **Tools → More tools → Plugin management**, enable **MediaCat**, and restart when prompted.
4. The built-in **OPDS** plugin does not need to be enabled. MediaCat loads its browser, parser, authentication client, and download workflow directly. Existing saved catalogs from OPDS Plus and the built-in OPDS plugin can be selected with **Saved catalogs** on the login screen.

### Wireless install on Kindle (SFTP)

You can copy the plugin over Wi-Fi without connecting the Kindle by USB. The Kindle and computer must be on the same local network.

1. In KOReader, open **Tools (cog) → Network → SSH server**.
2. For a quick one-time transfer, enable **Login without password (DANGEROUS)**, then enable **SSH server**. Note the IP address shown by KOReader.
3. On the computer, open an SFTP client (such as Cyberduck or FileZilla) and connect with:
   - Protocol: **SFTP**
   - Server: the IP address shown by KOReader
   - Port: `2222` (unless KOReader shows a different port)
   - Username: `root`
   - Password: `root`
4. In the remote files, open the Kindle storage and then `koreader/plugins/`. On many Kindle setups the storage is `/mnt/us`; on this Kindle it is `/mnt/us/koreader/plugins/`. Some KOReader setups expose it as `/mnt/onboard/koreader/plugins/`. Copy the entire `opds_home.koplugin` folder there.
5. In KOReader, disable **SSH server** and **Login without password (DANGEROUS)** after the copy. Restart KOReader, then enable **MediaCat** in **Tools → More tools → Plugin management**.

The passwordless SSH option allows logins from devices on the local network while it is enabled. Turn it off after transferring the plugin. For repeated development transfers, configure an SSH public key in KOReader instead of enabling passwordless login.

To remove MediaCat, disable it in Plugin management or delete `opds_home.koplugin`, then restart KOReader.

### Redeploy from a source checkout

From the KOReader repository, run `./tools/deploy_opds_home_to_kindle.sh`. It syncs MediaCat and its shared OPDS browser module to `root@192.168.0.58:2222`, under `/mnt/us/koreader`. The script uses `~/.ssh/id_ed25519_koreader_kindle` when present. Set `KINDLE_HOST`, `KINDLE_PORT`, `KINDLE_USER`, or `KINDLE_KOREADER_DIR` to override those defaults. Restart KOReader after deployment.

## Try it

1. On the FileManager screen, enter the root OPDS feed URL. Add a username and password if your server requires them.
2. Tap **Login**. MediaCat fetches the feed and displays its libraries or catalog entries.
3. Tap a library/folder to open it. In list view, tap **Load next catalog page…** to fetch another feed page.
4. A feed with books and no child catalogs opens in a cover grid. Use the bottom **More** control for another feed page. Tap a book, then choose a supported format in KOReader's standard download dialog.
5. Use **Back** to move up the catalog, or open **Menu → Edit OPDS login** to change the connection. **Return to local files** closes the overlay and shows KOReader's normal FileManager.

The URL, username, and password are saved locally in `settings/opds_home.lua` as soon as you submit the login, so a failed or interrupted connection does not make you re-enter them. The password is stored in that settings file in the same plain-text form used by KOReader's built-in OPDS catalog settings. Remove the saved connection by editing/deleting that file or clearing the plugin's settings through Plugin management.

## Current limits

- The browser displays catalog links in a list and only switches to the cover grid at a leaf feed.
- Grid covers come from OPDS image or thumbnail links. Entries without a cover show a placeholder.
- Only HTTP and HTTPS feed URLs are accepted. Authentication uses KOReader's built-in OPDS client behavior, including HTTP Basic authentication and catalog cookies. KOReader's client advertises OPDS 2.0 before Atom/OPDS 1.x; if the OPDS 2.0 response cannot be parsed, MediaCat retries with Atom preferred.
- Book taps use KOReader's existing OPDS download flow and download directory settings.
- MediaCat reuses internal modules from the built-in OPDS plugin, so keep it paired with the KOReader version you are testing. The built-in OPDS plugin's UI does not need to be enabled. OPDS Plus is a separate implementation and does not provide those modules.
- The first version does not add search, facets, borrowing, or OPDS page streaming to the custom browser. The built-in OPDS browser remains available from the Search menu.
- **Local files** returns to KOReader's normal FileManager at its current folder. It shows local storage, not a downloaded-books-only list; OPDS downloads go to KOReader's configured download folder.
- The catalog breadcrumb is not currently written into downloaded books or their KOReader metadata. If preserving catalog categories matters, the maintainable approach is a small local source record keyed by downloaded file, with catalog and breadcrumb fields, then expose it as filters in a dedicated downloads view.
- Since this screen overlays FileManager, it appears whenever KOReader opens FileManager. It does not override startup when KOReader resumes a previously open book, nor does it replace a reader page. Set **Start with** to **file browser** in File Browser settings if you want MediaCat immediately at launch.

## OPDS versions and connection troubleshooting

OPDS 1.x Atom feeds and OPDS 2.0 JSON feeds use the same HTTP request flow but different feed formats. A server can expose both from one URL using content negotiation (`Accept`), or use separate URLs; OPDS 2.0 is not a drop-in wire-format replacement for 1.x. Current KOReader code already negotiates for OPDS 2.0 and parses both formats, so MediaCat only needs OPDS 2.0 support if you want its server to offer that format. Keeping an OPDS 1.x feed is still useful for clients that do not support 2.0.

If MediaCat works in OPDS Plus but not here, the built-in **OPDS** plugin's UI does not need to be enabled. OPDS Plus has its own fetcher and parser, so compare the exact catalog URL and credentials in both plugins and check KOReader's `crash.log` / `verbose.log`. MediaCat requests OPDS 2.0 first and falls back to Atom when it cannot parse that response.

## Development location

In a source checkout, this plugin lives at `plugins/opds_home.koplugin/`. Copy that directory to a device's `koreader/plugins/` folder to try it. The normal built-in plugin path in a local development checkout is discovered automatically.
