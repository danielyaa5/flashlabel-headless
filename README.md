# flashlabel-headless

Print 4 x 6 in shipping labels on an **Arrvel A42BT** thermal label printer from a macOS terminal, over Bluetooth LE. The vendor's FlashLabel app does not need to be installed or running.

It renders a PDF or image at the printer's 203 dpi, builds a TSPL job, and sends it with the Bluetooth module's packet-credit flow control. Nothing is ever sent unless the module has granted a credit for it. The vendor template for this printer points at a different BLE path that drops data silently when you write too fast. With that path a job can "send" without errors and still print nothing.

## Tested scope

| Component | Verified configuration |
| --- | --- |
| Computer | macOS, Apple silicon, Xcode Command Line Tools (Swift 6 compiler, Swift 5 language mode) |
| Printer | Arrvel A42BT (advertises as `A42BT-XXXX_LE`), TSPL, 203 dpi |
| Media | 100 x 150 mm (4 x 6 in) die-cut labels with gaps |
| Input | 4 x 6 in label PDF from a marketplace shipping flow |
| Result | One label printed correctly. The module returned every packet credit (500 of 500) |
| Packaged CLI | `scan` and `check` (handshake only) run against the printer; print path uses the same transport, job format and settings as the hardware run |

Delivery is confirmed only at the Bluetooth level. The A42BT does not answer TSPL status queries (`ESC !?`, `~!T`) over BLE and does not report paper feed. A run that ends in "returned every credit" proves the whole job reached the printer's controller, not that a label came out. Check the printer.

The hardware print used the same credit-gated transport and TSPL header as this CLI, but an earlier prototype rendered its bitmap. For the same label PDF, this CLI's rasterizer produces a byte-identical header and a visually equivalent bitmap, with 3% of dots differing along anti-aliased edges. Letter-size PDFs, images, other label sizes and other printers that share the same BLE module are handled by the code and covered by offline tests, but they have not been tried on hardware. Intel Macs are untested.

## Requirements

- macOS 12 or newer with Bluetooth LE.
- Xcode Command Line Tools (`xcode-select --install`). There are no other dependencies: no SwiftPM packages, Homebrew or Python.
- The printer switched on and not connected to another phone or computer (a connected printer stops advertising).
- The first Bluetooth command makes macOS ask for Bluetooth access for your terminal app. Allow it, or enable it later in System Settings > Privacy & Security > Bluetooth.

## Use

```sh
git clone https://github.com/danielyaa5/flashlabel-headless.git
cd flashlabel-headless

./flashlabel scan                                 # list nearby A42BT printers
./flashlabel check                                # connect and handshake, prints nothing
./flashlabel shipping-label.pdf --dry-run --preview preview.png
./flashlabel shipping-label.pdf                   # print one copy
```

`./flashlabel` compiles the Swift sources into `.build/` on first use and again whenever a source file changes, then runs the binary. Run it from anywhere, or symlink it into your `PATH`.

Always check `--preview` before printing a new kind of document. The PNG shows exactly the dots that will be burned.

### Commands

| Command | What it does |
| --- | --- |
| `flashlabel print <file> [options]` | Render and print. `flashlabel <file>` is the same. |
| `flashlabel scan [--prefix P] [--wait-sec N]` | List advertising printers with RSSI and CoreBluetooth identifier. `--prefix ""` lists every named device. |
| `flashlabel check [--prefix P \| --identifier UUID]` | Connect, complete the credit handshake, disconnect. Nothing is sent. |

### Print options

| Option | Default | Meaning |
| --- | --- | --- |
| `--dry-run` | off | Build the job and write any requested files without using Bluetooth |
| `--preview FILE.png` | | Save the 1-bit image that will print |
| `--out-tspl FILE.bin` | | Save the complete TSPL job |
| `--raw` | `.bin` files | Send a file as an existing TSPL job |
| `--page N` | `1` | PDF page |
| `--rotate MODE` | `auto` | `auto`, `0`, `90`, `180` or `270` (clockwise) |
| `--crop MODE` | `auto` | `auto`, `none`, or `x,y,w,h` in PDF points (images: pixels), measured from the top-left corner |
| `--threshold N` | `128` | Gray level (1-254) below which a dot prints black |
| `--size WxH` | `100x150` | Label size in mm. The print head is 108 mm wide |
| `--gap MM` | `2` | Gap between labels in mm |
| `--density N` | `8` | Darkness, 1-15 |
| `--speed N` | `4` | Print speed |
| `--copies N` | `1` | Copies |
| `--prefix P` | `A42BT` | Bluetooth name prefix to match |
| `--identifier UUID` | | Choose one printer by identifier from `scan` |
| `--wait-sec N` | `30` | Time to wait for the printer to advertise |
| `--timeout N` | `120` | Time allowed for connecting and sending |
| `-v`, `--verbose` | off | Connection and transfer details |

Exit codes: `0` success, `1` usage, `2` input, `3` printer not found, `4` handshake, `5` transfer, `6` timeout, `7` Bluetooth unavailable or not permitted.

### Layout rules

- **Crop `auto`:** if the page already has the label's shape (4 x 6 in either orientation, within 3%), the whole page is used. Otherwise the page is trimmed to its non-white content plus a 1% margin. This is meant for the usual "label in the top half of a Letter page" PDF. If the page also contains a packing slip or instructions, auto crop keeps them too, so pass `--crop x,y,w,h` instead.
- **Rotate `auto`:** landscape content on a portrait label turns 90 degrees clockwise. Use `--rotate 270` if you want it the other way. Barcodes scan either way.
- **Fit:** the cropped area is scaled to fit 800 x 1200 dots with its aspect ratio kept, and centered.
- **Threshold:** anti-aliased rendering at printer resolution, then a single gray threshold. Barcodes stay crisp at the default.

## Protocol notes

The A42BT's Bluetooth module exposes several GATT services. This tool uses service `FF00`:

| Characteristic | Direction | Use |
| --- | --- | --- |
| `FF02` | write without response | Job bytes in |
| `FF03` | notify | Flow control: `01 nn` grants `nn` packet credits, `02 lo hi` gives the maximum payload (244 bytes after MTU exchange) |
| `FF01` | notify | Printer data out (stays silent during printing) |

On connect the module sends `01 07` (7 credits) and `02 F4 00` (244-byte payload). Each packet costs one credit, and the module hands it back with `01 01` as its buffer drains toward the printer's controller. The sender:

1. aborts before sending anything if the handshake does not arrive,
2. sends at most one packet per credit, never larger than the payload size or `maximumWriteValueLength(for: .withoutResponse)`, and only while CoreBluetooth reports `canSendWriteWithoutResponse`,
3. prefixes the job with `\r\n` to end any partial command line,
4. aborts if no credit arrives for 10 seconds (power-cycle the printer before retrying, since a partial bitmap may be buffered),
5. after the last packet, waits for every credit to come back before disconnecting.

The job is plain TSPL:

```
SIZE 100 mm,150 mm
GAP 2 mm,0 mm
DIRECTION 0,0
REFERENCE 0,0
DENSITY 8
SPEED 4
CLS
BITMAP 0,0,100,1200,0,<120000 bytes>
PRINT 1,1
```

`BITMAP` rows go top to bottom, 100 bytes per row, most significant bit first, with `0` = black and `1` = white. Lines end in `\r\n`.

The module also exposes Microchip's transparent UART service (`49535343-FE7D-...`). The vendor's printer template points at it (`8841` write, `1E4D` notify), but it acknowledges every write with the same five bytes, whatever was sent. Writing to it faster than its own flow control allows loses data without any error. A lost chunk inside `BITMAP` makes the printer swallow the following `PRINT` as image data, and nothing prints. `FF82` is the module's AT command port. Do not send printer data to it.

## Development

```sh
./tests/run.sh
```

This compiles the CLI and the tests with warnings treated as errors. It runs the unit tests (TSPL layout, bitmap packing and round trip, the credit state machine, and rasterizing synthetic 4 x 6 PDF, sideways Letter PDF and landscape PNG labels). Then it runs `./flashlabel --dry-run` end to end on those fixtures. The tests never use Bluetooth and never print.

Sources: [CLI](Sources/CLI/FlashLabelCLI.swift), [options and job building](Sources/Core/Options.swift), [rasterizer](Sources/Core/Raster.swift), [TSPL](Sources/Core/TSPL.swift), [credit flow control](Sources/Core/CreditGate.swift), [CoreBluetooth transport](Sources/Core/BLE.swift).

## License

[MIT](LICENSE). This project is unaffiliated with Arrvel or FlashLabel. Product names belong to their owners.
