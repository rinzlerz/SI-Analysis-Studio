# SI Studio (Phases 1–4)

Quick signal-integrity analysis for PCB layout, as an offline Android app (Flutter).
You pick a protocol (SPI, USB 2.0, USB 3.0 or PCIe Gen 1–5), enter stackup, routing, driver, receiver and
termination values, and tap **Generate Quick SI Analysis**. The app runs a
time-domain transmission-line simulation built from those values and shows the
waveforms, SI metrics, Good / Warning / Critical status and recommendations.

> Preliminary engineering tool. It does not claim protocol compliance. Every metric
> is labelled with the modelling level that produced it (L1 analytical, L2 behavioural).

---

## Web version

**Live app:** https://rinzlerz.github.io/SI-Analysis-Studio/ – rebuilt automatically from `main` by `.github/workflows/deploy-web.yml`.

**Android APK:** https://github.com/rinzlerz/SI-Analysis-Studio/releases/latest – built automatically by `.github/workflows/android-apk.yml` for the version in `pubspec.yaml`.

**Feedback:** https://github.com/rinzlerz/SI-Analysis-Studio/issues/new?template=feedback.yml (also from the app: Home → feedback icon, or a result's ⋮ → *Report a problem*, which pre-fills a link to that analysis).

**Layout guidelines (v0.7):** Home → *Layout guidelines*, or New Analysis → ⋮. Before routing, pick an interface and get, for the current stackup:
- trace width per layer for the impedance target, plus the ±10 % width window;
- propagation delay;
- maximum length, from timing, loss or the I²C capacitance budget;
- P/N, clock-to-data or lane matching;
- spacing for crosstalk (Kb);
- via count and the via-stub limit (back-drill);
- termination.

**Diagrams (v0.8):** the sheet draws its numbers. You get a length gauge (max length versus your current trace), a stackup cross-section with W/S/H dimensions, a top-view routing sketch (pair spacing, serpentine matching, AC caps, GND stitching vias; bus pitch and series R; I²C pull-ups and taps), and, for differential interfaces, a via-stub picture for the selected layer. The same figures are included in the PDF export. Figure model: `lib/simulation/guidelines/figures.dart`.

Export it as a PDF, as KiCad rules + CSV, or as text. Engine: `lib/simulation/guidelines/guidelines.dart`.

**Per-signal lengths (v0.9):** for SPI, QSPI/OSPI and RGMII, switch on *Per-signal lengths* in section C and enter each line's routed length (SCLK/MOSI/MISO/CS; CLK/IO0–7/CS#/DQS; TXC/TXD0–3/TX_CTL and RXC/RXD0–3/RX_CTL). The simulation times every group on its own clock with its longest and shortest data line, reports the data-line spread, and names the line that limits setup or hold. KiCad import can fill the table automatically (*Use as bus*: net names such as `SPI1_SCK`, `QSPI_IO2`, `ETH_TXD0`, `ETH_RX_DV` are matched). The guideline sheet shows each line's length and marks lines outside the matching budget in red. Model: `lib/simulation/model/bus_lengths.dart`.

**Share links:** *Share link* on a result, or *Share these inputs* in New Analysis, creates a URL that reopens the exact analysis for anyone. The configuration travels in the URL fragment and is never uploaded. IBIS / Touchstone models are not included.

**Web worker:** on the web the engine runs in `sim_worker.js`, compiled from `lib/simulation/worker/sim_worker.dart` by the Pages workflow. With `flutter run -d chrome` there is no worker, and the app falls back to the main thread.

The same code also runs in a browser: there is nothing to install, so it is easy to share with testers. See **[WEB_DEPLOY.md](WEB_DEPLOY.md)** to try it locally (`flutter run -d chrome`) and publish it on GitHub Pages (automatic workflow included) or Netlify.

On the web:
- Analyses are stored in the browser (IndexedDB).
- Exports download to the Downloads folder.
- Wide screens get a side navigation bar, and the waveform viewer zooms with the mouse wheel (Shift + wheel pans).

Home has one-tap example analyses, and **About** (Home ⓘ or Settings) explains limitations and privacy.

## 1. Build and run (Windows)

Prerequisites: [Flutter SDK](https://docs.flutter.dev/get-started/install/windows/mobile)
(3.27 or newer; developed against 3.50), Android Studio with an Android SDK, and a
phone with USB debugging enabled or an emulator.

```powershell
cd "SI Quick Analysis - Claude"
.\setup_android.bat          # one-time: generates android/, installs packages, runs tests
flutter run                  # run on the connected phone / emulator
flutter build apk --release  # APK -> build\app\outputs\flutter-apk\app-release.apk
flutter build appbundle      # AAB for Play Store
```

`setup_android.bat` runs `flutter create --platforms=android .`, which adds the Android
platform folder without overwriting the files in `lib/` and `test/`. It also renames the
launcher label to "SI Studio", then runs `flutter pub get` and `flutter test`.

## 2. What is implemented (PRD Phase 1)

| PRD item | Status |
|---|---|
| Protocol selection: SPI, USB 2.0 (HS / FS) | Done. USB 3.0 / PCIe are shown as Phase 2 |
| Protocol-specific parameters | Done (SPI modes 0–3, VDD 1.8/3.3/custom, tCO/setup/hold, VIH/VIL; USB speed, edges, terminations) |
| PCB stackup editor + visualisation | Done: 2/4/6/8-layer presets, per-layer role/copper, per-dielectric thickness, Dk, Df, signal layer |
| Impedance: microstrip, stripline, differential | Done, live preview, plus a "Set width for target" solver |
| Propagation delay, electrical length, critical length | Done (L1) |
| Reflection coefficients, termination models | Done: none, series, parallel-to-VTT, AC (RC), series + parallel; USB on-die 45 Ω |
| Frequency-dependent loss | Done: skin effect + dielectric loss, causal (minimum-phase) |
| Time-domain waveforms | Done: ideal vs TX vs RX, incident and reflected waves, D+/D−/Vdiff/Vcm |
| Eye diagram (USB 2.0) | Done: folded from the simulated waveform; deterministic metrics only |
| SPI timing | Done: MOSI setup/hold at the peripheral, MISO setup/hold at the controller (includes round trip + tCO) |
| Metrics, explicit thresholds, findings, recommendations | Done; thresholds are editable in Settings |
| Waveform viewer | Pinch zoom (X / Y / XY), pan, double-tap fit, A/B cursors (ΔV, Δt, 1/Δt), Vmax/Vmin/Vpp, rise/fall, overshoot, trace visibility, full-screen landscape |
| History (offline SQLite) | Auto-save, open, load into editor, rename, duplicate, delete |
| Export | CSV waveforms, JSON analysis, plain-text report through the Android share sheet |
| PDF report | Added in Phase 3 |

### Phase 2 additions

| PRD Phase 2 item | Status |
|---|---|
| USB 3.0 model | 5 Gb/s differential link, TX de-emphasis, RX termination/capacitance, behavioural CTLE |
| PCIe model | Gen 1–5 (2.5–32 GT/s), x1–x16 with lane-to-lane skew, Gen1/2 de-emphasis, Gen3+ TX presets P0–P10, CTLE (auto-optimised), 1–5 tap DFE |
| Eye diagram generation | Raw eye at the RX pin plus the post-equalisation eye, classified against editable reference RX eye minimums |
| Jitter estimation | Deterministic jitter from the simulation; optional user RJ gives TJ ≈ DJ + 14.07·RJ (BER 1e-12) |
| Frequency-dependent attenuation / improved channel model | Copper roughness (Hammerstad-Groiss) added to skin-effect + dielectric loss; IL at Nyquist with conductor/dielectric split |
| Differential skew analysis | Intra-pair (all differential protocols) and lane-to-lane (PCIe) |
| Signal propagation animation | Voltage along the trace, time-locked to the computed delay and reflections, with play/pause, scrub and speed |

SerDes model notes:
- **TX FIR:** 3 taps, from preshoot/de-emphasis.
  - Vb = 1/(rP + 1/rD − 1), |c−1| = Vb(rP−1)/2, |c+1| = Vb(1/rD−1)/2.
  - This reproduces the PCIe preset table, for example P7 = −0.1 / 0.7 / −0.2.
- **CTLE:** behavioural, Kdc(1+s/ωz)/((1+s/ωp1)(1+s/ωp2)), with poles at fN/2 and 2fN.
- **DFE:** ideal decisions, with least-squares post-cursor taps.
- **Not included:** packages, vias, connectors, AC-coupling caps, encoding/scrambling and crosstalk. Results are trace-only, not compliance.

### Phase 3 additions (Level 3 – advanced engineering)

| PRD Phase 3 item | Implementation |
|---|---|
| IBIS model import | `.ibs` parser ([Model], C_comp, Vinl/Vinh, [Voltage Range], [Pullup]/[Pulldown]/[GND Clamp]/[POWER Clamp], [Ramp]); typ/min/max corners; nonlinear driver (V-I tables switched by the ramp) and receiver clamps solved by Newton iteration. Used for SPI drivers/receivers |
| S-parameter import | Touchstone v1 `.s2p` (S21) and `.s4p` (mixed-mode SDD21/SDD11, two port mappings) for USB 3.0/PCIe; causal impulse response, IL/RL from the file |
| Crosstalk analysis | Coupled-line even/odd modes (Kirschning-Jansen microstrip, Cohn stripline) in a time-domain coupled-line model; NEXT/FEXT, Kb, saturation length, spacing recommendation |
| Via discontinuity modelling | Johnson via π-model (pad C, barrel L) + open-stub transmission line; stub resonance check |
| Connector / package modelling | Impedance + delay segments anywhere along the route; AC-coupling caps (C + ESL + pads); ESD/test-pad shunt C |
| Advanced eye analysis | Hexagon eye-mask hits; statistical bathtub (simulated DJ distribution ⊗ user RJ) and eye width at BER 1e-12 |
| Protocol compliance checks | Per-protocol reference checks (spec-derived or configured limits, clearly labelled, not certification) |
| Advanced reporting | PDF report with waveform and eye images, metrics, findings, checks and assumptions; plus CSV/JSON/text |

Also new:
- **Coupled-line differential impedance:** now the default. Pairs propagate at the odd-mode velocity. Analyses saved earlier keep the IPC-2141 model so their results don't change.
- **Multi-segment channels:** handled by a general modified-nodal-analysis time-domain solver with Branin lines, R/L/C companions, coupled lines and nonlinear devices.

### Phase 4 additions (libraries, comparison, PCB-tool integration)

| PRD Phase 4 item | Implementation |
|---|---|
| Reusable stackup libraries | **History → Libraries** (also from Settings). Four built-in FR-4 stackups (2/4/6/8 layers) plus your own. In New Analysis, **Stackup library** loads a stackup into the analysis and **Save to library** stores the current one |
| Component / driver model libraries | Driver/receiver presets per protocol (section D, **Load preset / Save preset**). IBIS models and Touchstone channels can be saved once and reused (**From library / Save to library**). Every library entry can be exported to `.json` and imported back, so a team can share one set |
| Comparison between routing configurations | **History:** long-press to select 2–8 analyses, then tap **Compare**. **New Analysis:** tap the sweep icon to vary one parameter (length, width, spacing, P/N mismatch, series R, driver impedance, receiver C, clock, dielectric height or via stub) over 2–8 values. The comparison shows each overall status, a metrics table coloured by status, a metric-vs-parameter chart for sweeps, an overlay of the receiver waveforms, and CSV export. Tap a configuration to open its full results or edit it |
| PCB design-tool integration | **Import from KiCad** (board icon in New Analysis): reads a `.kicad_pcb` (KiCad 6–8) and takes its stackup, plus the length, width, layer and via count/stub of any net or differential pair. **Export design rules** (results menu) writes a KiCad custom-rules file (`.kicad_dru`) with width, gap, length, skew and via-count limits from the analysis, and a CSV constraint table for Altium, Allegro and other tools |

### Additional protocols (SIM-1.3.0)

| Protocol | Model | What it checks |
|---|---|---|
| **I²C** (Standard / Fast / Fast-mode Plus) | Open-drain driver with slope-controlled fall, pull-up to VDD, bus capacitance from trace + device pins + extras (new circuit-solver model) | Rise time (30–70 %), fall time, bus capacitance vs 400/550 pF, allowed pull-up range and a recommended E12 value, VOL / noise margin, effective tLOW/tHIGH, tSU;DAT, ringing. Limits from NXP UM10204 |
| **QSPI / Octal SPI** | SPI engine extended with x4/x8, SDR or DTR, IO-to-CLK length mismatch, read capture delay and DQS read strobe | Write setup/hold at the flash, read timing at the controller (round trip + flash tV), **recommended read sample delay** found by sweeping the capture point |
| **Ethernet RGMII** (1000/100/10) | Source-synchronous clock + data, edge-aligned launch, internal "RGMII-ID" delay and/or PCB clock delay, TskewT | Setup/hold at PHY (TX) and MAC (RX), best clock delay, detection of a missing or double 2 ns delay, clock edge rate, ringing |
| **HDMI** (TMDS 1.65 / 3.4 / 6 Gb/s, FRL 12 Gb/s) | SerDes engine with 100 Ω pairs, CTLE/DFE for HDMI 2.x | Eye vs approximate reference minimums, intra-pair and inter-pair skew, trace loss guideline (board only, the cable is excluded) |

Also fixed: the ring-back measurement started before the edge finished, which reported a spurious "low ring-back margin" warning on clean SPI edges.

## 3. Project structure

```
lib/
  main.dart, app.dart               app entry, bottom navigation shell
  core/  theme/ utilities/ state/   dark scope theme, display units, AppController
  data/  models/ repositories/ local_database/   records, settings, sqflite storage
  features/
    home/ analysis_input/ pcb_stackup/ waveform/ analysis_results/ history/ settings/
    library/ compare/ integration/  Phase 4 screens
    about/                          About, limitations, privacy, licences
  platform/                         storage / file export / links: *_io.dart (Android) vs *_web.dart (browser)
  shared/ widgets/ export/          engineering input field, section cards, CSV/JSON export
  simulation/                       PURE DART: no Flutter imports, runs in a background isolate
    model/              config + result data (JSON-serialisable, versioned SIM-1.0.0)
    impedance/          Hammerstad-Jensen, Wheeler, offset stripline, IPC-2141 coupling, width solver
    transmission_line/  delay, velocity, R(f), alpha_c, alpha_d, insertion loss
    reflection/         Gamma, return loss, analytical lattice diagram
    termination/        source/load end networks, DC operating point
    channel_loss/       FFT + minimum-phase loss impulse response
    waveform_engine/    stimulus/patterns, Branin line solver, link preparation
    metrics/            edge stats, ring-back, settling, timing windows, eye, classification
    equalization/       TX FIR / presets, CTLE, DFE
    ibis/               IBIS parser + nonlinear driver/receiver devices
    sparams/            Touchstone parser, impulse response, convolution
    integration/        KiCad .kicad_pcb import, .kicad_dru / CSV rule export
    comparison/         sweep parameters
    protocols/          spi_sim.dart (SPI, QSPI/OSPI), usb2_sim.dart, serdes_sim.dart (USB 3.0, PCIe, HDMI),
                        i2c_sim.dart, rgmii_sim.dart
    validation.dart     input validation with explicit messages
    engine.dart         runAnalysis(config) -> SimulationResult
test/simulation/        impedance, line-solver, loss and protocol tests
```

## 4. Electrical models

**Impedance (L1).**
- Microstrip: Hammerstad & Jensen with the thickness correction, quasi-static.
- Symmetric stripline: Wheeler, including thickness.
- Offset stripline: Z = 2·Z(b1)·Z(b2)/(Z(b1)+Z(b2)).
- Differential pairs: IPC-2141, Zdiff = 2·Z0·(1−0.48·e^(−0.96 s/h)) for microstrip and 2·Z0·(1−0.347·e^(−2.9 s/b)) for stripline. Expect ±5–10 %.
- Solder mask and copper roughness are not modelled.

**Line (L1).**
- tpd = √εeff / c₀ and T = tpd·L.
- The line is called electrically long when T > tr/6.
- Γ = (ZL − Z0)/(ZL + Z0).

**Loss.**
- Conductor: α_c = R(f)/(2Z0), with R(f) = √(Rdc² + Rac²), Rac from the skin-effect surface resistance Rs on the strip plus the ground-return spreading width W + 2πh.
- Dielectric: α_d = (πf/c₀)·εr/√εeff·(εeff−1)/(εr−1)·tanδ for microstrip, and (πf/c₀)·√εr·tanδ for stripline.
- The magnitude response exp(−αL) becomes a causal minimum-phase impulse response through the real cepstrum.

**Time domain (L2).**
- Method of characteristics (Branin), which is exact for lossless lines: each end is a Thevenin source e(t) = v(t−T) + Z0·i(t−T) behind Z0.
- Each end network is solved with one nodal equation per time step. Capacitors use trapezoidal companion models, and loss is applied as a convolution on the travelling waves.
- Fractional delays use linear interpolation.
- The time step is min(edge/40, T).
- When the line is quiet, the solver skips the convolution, so SPI at 1 MHz (740 k steps) runs in about 0.2 s.

**USB 2.0.**
- Each leg is simulated with the odd-mode impedance Zdiff/2.
- HS driver: 0.8 V Thevenin source behind 45 Ω (17.78 mA into 45 Ω), with a 45 Ω on-die receiver termination.
- FS driver: 3.3 V CMOS source with series resistance; the receiver is unterminated.
- The D− length mismatch produces skew and common-mode.

**SPI.**
- SCLK, MOSI and CS are driven by the controller; MISO is driven by the peripheral tCO after SCLK *arrives* at its pin.
- Setup slack = t_sample − t_valid − t_su, where t_valid is the last entry into the ≥ VIH / ≤ VIL region.
- Ring-back below VIH (or above VIL) after an edge is reported as a double-clocking risk.

## 5. Verification

The engine tests run with `flutter test`:
- **Microstrip Z0 / εeff:** match scikit-rf 2.2 `MLine` (an independent Hammerstad-Jensen implementation) within 0.01 Ω.
- **Wheeler stripline:** within 0.5 % of Cohn's exact solution, K(k)/K(k').
- **Line solver:** reproduces the analytical lattice diagram. Examples: matched source with an open load; a 25 Ω source with an open load settling 4/3 V → 8/9 V → …; series termination; parallel termination; RC charging with τ = Z0·C; AC termination; fractional delay.
- **Loss model:** the minimum-phase impulse reproduces |H(f)| within 1 % and keeps the exact DC gain.
- **PRD acceptance checks:**
  - Changing trace length scales the delay.
  - Changing width changes Z0, Γ and the waveform.
  - Series termination lowers overshoot.
  - A long trace at a high SCLK violates MISO setup.
  - A matched USB HS pair gives 400 mV and an open eye.
  - Length mismatch gives skew.
  - Invalid input is rejected.

## 6. Known limitations / next steps

- All four SPI signals share one length and termination. Per-signal lengths are a simple extension.
- No NRZI, bit stuffing or SYNC for USB; no 8b/10b or 128b/130b encoding for SerDes.
- **Not supported:**
  - IBIS-AMI, V-T waveform tables and package RLC.
  - Touchstone 2.0 keyword files.
  - Full-wave via, connector and package fields. The via is a lumped model plus a stub.
- **Crosstalk:** covers the coupled section only, uses one aggressor, and is lossless.
- **KiCad import:**
  - Lengths are the routed copper (segments and arcs). Pad-to-pad escape inside footprints and via barrel length are not added.
  - Via stubs assume through vias. Blind and buried vias use their real span.
  - Altium/Allegro import is not available; for those tools use the CSV rule export, or set parameters by hand.
- **Sweeps:** run one after another on the device (about 1–5 s per configuration).
- **I²C:** acknowledge bits and clock stretching by targets are not simulated; all target pins are lumped at the far end (worst case); channel elements are ignored (enter their capacitance as "other capacitance").
- **RGMII:** one data line represents the group; TX and RX share routing and differ only in clock delay.
- **QSPI:** IO0 represents all IO lines; the read path ignores a series resistor placed at the controller end.
- **HDMI:** eye minimums are approximations, not the HDMI compliance test specification.
- **Not yet supported:** DDR3/DDR4/LPDDR4, MIPI D-PHY, eMMC/SD, LVDS, CAN/RS-485.
