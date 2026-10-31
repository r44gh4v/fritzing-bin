# fritzing-bin

Get [Fritzing](https://fritzing.org) for Windows, macOS or Linux without paying, built by GitHub from the [official source code](https://github.com/fritzing/fritzing-app).

This project is not part of the Fritzing project. It does not change the Fritzing source code.

> [!NOTE]
> The official builds cost money at [fritzing.org](https://fritzing.org). This money helps the Fritzing team.
> If you use Fritzing frequently, buy the official build.

You need a free [GitHub account](https://github.com/signup). You do not need to install anything.

## Part 1: Make your build

1. Sign in to GitHub.
2. At the top of this page, click **Fork**. Then click **Create fork**. You now have your own copy of this project.
3. In your copy, click the **Actions** tab. Click the green button **I understand my workflows, go ahead and enable them**.
4. In the list on the left, click **fritzing**.
5. On the right, click **Run workflow**. A small window opens.
6. Tick the box for your computer. You can tick more than one box. You get one file for each box. If you tick no box, the run stops with a message.

   - **Windows (x64)**: all normal Windows 10 and 11 computers
   - **MacOS (Intel and Apple Silicon)**: all Macs that Qt supports (macOS 13 or newer)
   - **Linux (x64)**: Ubuntu 22.04 or newer, Debian 12, Fedora, Arch and most other distributions

7. Leave **Fritzing version** empty. You get the latest stable version.
8. Click the green **Run workflow** button.
9. Wait. After a few seconds, a new line appears. When it shows a green check mark, the build is ready. This takes 10 to 60 minutes. Refresh the page to see the progress.
10. Click the line with the green check mark.

## Part 2: Install and start Fritzing

On the page of your build, scroll down to **Artifacts**. Click the file name to download it.

GitHub deletes the file after 2 days. To get it again, do Part 1 from step 4.

### Windows

1. Right-click the downloaded `.zip` file. Select **Extract All**, then **Extract**. Fritzing does not start from inside the zip file.
2. Open the new folder. Double-click **Fritzing** (Fritzing.exe).
3. First start only: Windows shows "Windows protected your PC", because this build is not signed. Click **More info**, then **Run anyway**.

### MacOS

1. Double-click the downloaded `.zip` file. You get **Fritzing**. Drag it into your **Applications** folder.
2. Double-click **Fritzing**. macOS shows a warning, because Apple did not check this build. Click **Done** (or **Cancel**).
3. First start only: open **System Settings**, then **Privacy & Security**. Scroll down and click **Open Anyway** next to "Fritzing". Enter your password. Click **Open Anyway** again.

If macOS says the app "is damaged", open **Terminal**, paste this line, press Return, and start Fritzing again:

```
xattr -cr /Applications/Fritzing.app
```

### Linux

1. Open a terminal in the folder with the downloaded `.AppImage` file. For the Downloads folder, type `cd ~/Downloads` and press Enter.
2. First time only: allow the file to run. Type `chmod +x` and the file name, and press Enter.
3. Start Fritzing: type `./` and the file name, and press Enter. After step 2, a double-click on the file also starts it in most file managers.

For example:

```
cd ~/Downloads
chmod +x fritzing-1.0.8-linux-x64.AppImage
./fritzing-1.0.8-linux-x64.AppImage
```

If you see an error about FUSE, start it with `--appimage-extract-and-run` after the file name:

```
./fritzing-1.0.8-linux-x64.AppImage --appimage-extract-and-run
```

The Linux build is an AppImage: one file that contains Fritzing and the libraries it needs. It runs on most distributions with glibc 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora 36, Arch and newer). You do not need to install it.

## Other versions

| In **Fritzing version**, type | You get |
|---|---|
| (nothing) | The latest stable version, for example `1.0.8` |
| `1.0.7` | An older version |
| `develop` | The latest development code. It can be unstable. |

These computers are not supported:

- **32-bit Windows.** Fritzing needs Qt 6, which does not support it.
- **Windows on ARM.** The simulator library does not exist for it. The Windows (x64) build runs on these computers through emulation.
- **Linux on ARM.**

The build reads the Qt version and the versions of all libraries from the Fritzing source code. It also takes the newest parts library. New Fritzing versions do not need changes to this project.

## Licenses

This is not legal advice.

- **Fritzing** uses the [GPL v3](https://github.com/fritzing/fritzing-app/blob/develop/LICENSE.GPL3). You can build it and use it.
- **Fritzing parts and documentation** use [CC BY-SA 3.0](https://github.com/fritzing/fritzing-app/blob/develop/LICENSE.CC-BY-SA).
- **The files in this repository** use the [MIT license](LICENSE).

Each build contains the license files and a `SOURCE.txt` file, which shows where the source code is.

If you give a build to other persons, obey the GPL: include the license files, tell them where the source code is, and publish any changes you make. If you change Fritzing, do not call your version "Fritzing".

Your fork is public. Other GitHub users can download your build until GitHub deletes it.

## For developers

The workflow runs `build.ps1` (Windows) or `build.sh` (macOS, Linux). You can run them on your own computer. You need Qt 6.5.3 to 6.10, CMake, Git, Python 3 and a C++ compiler (Visual Studio on Windows). `.github/workflows/fritzing.yml` shows all requirements.

```
pwsh build.ps1 [-Ref 1.0.7]          # Windows
bash build.sh linux|macos [1.0.7]     # MacOS, Linux
```

The result goes into the `github` folder.

## Thanks

This project uses the idea of [mmozeiko/aseprite-bin](https://github.com/mmozeiko/aseprite-bin).
