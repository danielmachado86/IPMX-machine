# IPMX Phase 0 — bucle RTP puro

ScreenCaptureKit → x264/x265 → RFC 6184/7798 → UDP multicast → VideoToolbox → ventana.

**H.264 y H.265 conviven**: `--codec h264|h265` en ambos binarios. IPMX exige los dos, y poder
hacer A/B entre ellos es lo que hace falta para la Fase 1.

Sin RTCP, sin NMOS, sin PTP. El objetivo de esta fase es **ver imagen**: cerrar el bucle
extremo a extremo para tener sobre qué construir la conformidad de las fases siguientes.

El plan completo y la justificación normativa están en
[IPMX-macOS-encoder-decoder.md](IPMX-macOS-encoder-decoder.md). Los PDF de VSF fijados
están en [specs/](specs/).

---

## Requisitos

- macOS 26+ (probado en macOS 26.5, Apple Silicon). El código en sí solo necesita macOS 14;
  el suelo lo impone la libx264 de Homebrew, cuya bottle se compila con deployment target 26.
  Para bajarlo hay que compilar x264 desde fuente con `-mmacosx-version-min=14.0` y ajustar
  `platforms:` en [Package.swift](Package.swift).
- Swift 6. Para **compilar y ejecutar** bastan las Command Line Tools; para `swift test`
  hace falta **Xcode completo**, porque XCTest y swift-testing se distribuyen con Xcode y no
  con las CLT. Si `swift test` falla con `no such module 'XCTest'`, comprueba a dónde apunta
  el toolchain:

  ```bash
  xcode-select -p
  ```

  Si responde `/Library/Developer/CommandLineTools`, cámbialo con
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- `brew install x264 x265 pkg-config`
- Permiso de **Screen Recording** para la aplicación de terminal desde la que lances el
  encoder: System Settings → Privacy & Security → Screen Recording. macOS atribuye el
  permiso al terminal, no al binario; tras concederlo hay que reiniciar el terminal.

## Compilar

```bash
swift build -c release
```

## Probar sin red

Todo en un solo Mac, sobre loopback, sin switch ni multicast:

```bash
./scripts/run-local-loop.sh          # H.264
./scripts/run-local-loop.sh h265     # H.265
```

O a mano, en dos terminales:

```bash
swift run ipmx-encoder --codec h265 --dest 127.0.0.1 --iface 127.0.0.1 --sdp sdp/h265.sdp
```

```bash
swift run ipmx-decoder --sdp sdp/h265.sdp --iface 127.0.0.1
```

El decoder saca el códec, el destino, el puerto y los parameter sets del propio SDP, así que
`--codec` en el receptor solo hace falta si no le pasas `--sdp`.

El encoder escribe `sdp/stream.sdp` en cuanto tiene SPS/PPS; el decoder puede leer de ahí el
destino, el puerto y los parameter sets, que es lo que le entregaría una conexión IS-05 real.

## Probar en multicast

```bash
swift run ipmx-encoder --dest 239.10.10.10 --port 50000
swift run ipmx-decoder --group 239.10.10.10 --port 50000
```

Sin `--iface`, ambos eligen la primera interfaz IPv4 no-loopback activa. En un Mac con Wi-Fi
más un adaptador Thunderbolt querrás fijarla a mano. El switch necesita IGMP snooping **con
querier**; sin querier el tráfico se inunda o desaparece a los pocos minutos.

## Verificar

```bash
swift test
```

El target usa **los dos frameworks a la vez**, con un reparto deliberado:

- **swift-testing** (`import Testing`) para todo el comportamiento: 61 tests en 11 suites.
  Los casos parametrizados con `@Test(arguments:)` son la razón principal — casi todo se
  ejecuta **contra los dos códecs** a partir de la misma tabla (`arguments: VideoCodec.allCases`),
  igual que los atributos que exigen las TR y los tamaños de NAL alrededor del umbral de
  fragmentación. Cada fallo se reporta con su argumento concreto.
- **XCTest** para las medidas de rendimiento en
  [ThroughputTests.swift](Tests/IPMXCoreTests/ThroughputTests.swift). swift-testing todavía
  no tiene API de medición, así que `measure` sigue siendo la única forma de fijar líneas
  base y detectar regresiones.

Para ejecutar solo una parte:

```bash
swift test --filter "RFC 6184"
```

Cifras medidas en un M4 Pro, que son las que importan para la Fase 3: paquetizar un keyframe
de 1080p de 200 KB cuesta **~80 µs**, en torno al 0.5 % de un intervalo de frame a 60 fps.
El hilo real-time que hará el shaping CINST/CMAX tiene margen de sobra.

---

## Estructura

```
Package.swift
Sources/
  CX264/  CX265/            módulos de sistema para libx264 y libx265
    module.modulemap
    shim.h                  envuelve los macros *_encoder_open versionados y los arrays de las
                            structs de picture
  IPMXCore/                 todo lo que comparten los dos extremos y los dos códecs
    VideoCodec.swift        h264 | h265, y el tamaño de cabecera NAL del que cuelga todo
    NALUnit.swift           tipos de NAL de ambos códecs, Annex B, conversión a AVCC/HVCC
    RTPPacket.swift         cabecera RTP fija (RFC 3550 §5.1)
    VideoPacketizer.swift   RFC 6184 FU-A y RFC 7798 FU, sin agregación
    VideoDepacketizer.swift reensamblado, detección de huecos, STAP-A/AP en ingesta
    RTPStreamSender.swift   sella timestamps y marker bit, empuja al socket
    UDPSocket.swift         emisión/recepción UDP, membresía multicast, selección de interfaz
    MediaClock.swift        reloj de 90 kHz de marcha libre (ts-refclk:localmac)
    SDP.swift               fmtp por códec, profile_tier_level, des-escapado de RBSP
    CommandLineOptions.swift
  ipmx-encoder/
    main.swift
    ScreenSource.swift        captura ScreenCaptureKit en NV12
    VideoEncoder.swift        protocolo común y configuración
    X264Encoder.swift         libx264, NV12 directo
    X265Encoder.swift         libx265, requiere I420 planar
    ChromaDeinterleaver.swift NV12 -> I420 con vImage, solo para x265
  ipmx-decoder/
    main.swift
    VideoToolboxDecoder.swift H.264 y HEVC
    PlayerWindow.swift        AVSampleBufferDisplayLayer
Tests/IPMXCoreTests/
  TestNALUnits.swift        constructores de NAL sintéticos para ambos códecs
  PacketizationTests.swift  swift-testing: cabeceras NAL, Annex B, FU, round trip, pérdidas
  RTPHeaderTests.swift      swift-testing: cabecera RTP y reloj de 90 kHz
  SDPTests.swift            swift-testing: SDP por códec, RBSP, direccionamiento, flags
  ThroughputTests.swift     XCTest: medidas de rendimiento, ambos códecs
scripts/
  net-tuning.sh             sysctl de buffers UDP
  run-local-loop.sh
sdp/                        generado por el encoder
```

---

## Qué ya cumple la norma, y qué no

Ya alineado con las TR, porque cambiarlo después sale caro:

- Reloj RTP de **90 kHz** y timestamp compartido por todos los paquetes de un frame (TR-10-7 §9)
- **Un solo VCL NAL por paquete UDP** (TR-10-15 §9) — nunca se agrega con STAP-A
- Puerto UDP **par y > 5000**, con aviso si lo cambias (TR-10-7 §7)
- Random access point cada ≤ 5 s, con el flag limitado a ese máximo (TR-10-15 §11)
- **Decode order = output order**, sin B-frames (TR-10-15 §10)
- Perfil **High** (H.264) forzado de verdad: los presets rápidos de x264 apagan CABAC y el
  transform 8x8, y `x264_param_apply_profile` solo restringe, nunca eleva, así que
  `--preset ultrafast` produce en silencio Constrained Baseline — que TR-10-15 Part 3 §12 no admite
- Perfil **Main** 8 bits 4:2:0 (H.265), el mínimo de TR-10-15 Part 2 §12
- **PACI descartado** en ingesta: TR-10-15 Part 2 §9 prohíbe emitirlo
- `nuh_layer_id` y `nuh_temporal_id_plus1` preservados al fragmentar y reconstruir (RFC 7798)
- El `profile_tier_level` del SPS de H.265 se lee **tras des-escapar el RBSP**: cae justo donde
  los encoders insertan emulation prevention bytes, e indexar en crudo da un perfil plausible
  pero equivocado
- VUI con colorimetría BT.709 y rango limitado, coherente con el `RANGE=NARROW` del SDP
- SDP con `TP=2110TPW`, `ts-refclk:localmac`, `mediaclk:direct=0`, `b=AS:`

Deliberadamente fuera de esta fase:

| Falta | Fase | Nota |
|---|---|---|
| RTCP Sender Reports + IPMX Info Block | 2 | Nada de esto existe en ninguna librería; hay que escribirlo entero |
| HRD Type II, Buffering Period / Picture Timing SEI | 1 | `--hrd` ya enciende el señalizado en x264 y x265; falta validar el SPS |
| Traffic shaping CINST/CMAX | 3 | Necesita hilo real-time; macOS no tiene `SO_TXTIME` |
| NMOS IS-04 / IS-05 / IS-11 | 4 | `sony/nmos-cpp` cubre IS-04 e IS-05; IS-11 es propio |
| PTP | — | Innecesario mientras se opere en `ts-refclk:localmac` |
| Buffer de recepción y reordenado | 4 | Ahora se asume entrega en orden en una LAN tranquila |
| Cadencia constante con pantalla estática | 2 | ScreenCaptureKit solo entrega frames cuando algo cambia, así que el stream se para en un escritorio inmóvil. TR-10-15 §15 exige cadencia fija y prohíbe saltarse el Sender Report de un frame |
| Media Info Block 0x0009 / 0x000A | 2 | Los datos del códec para el RTCP; el SDP ya los calcula |
| Main10 (H.265 10 bits) | — | La ruta vImage pasaría a 16 bits. Main 8 bits es el mínimo de TR-10-15 Part 2 §12 |

---

## Siguiente paso concreto

```bash
swift run ipmx-encoder --hrd --dest 127.0.0.1 --iface 127.0.0.1
```

y después volcar el SPS del stream para comprobar que
`nal_hrd_parameters_present_flag = 1`. Ese es el primer entregable de la Fase 1, y es
también la medición que decide si VideoToolbox puede llegar a sustituir a x264 en el
camino de producción.
