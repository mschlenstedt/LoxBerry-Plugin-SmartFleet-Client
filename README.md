# SmartFleet Client

LoxBerry-Plugin für das SmartFleet-Flottenmanagement. Es läuft beim Kunden auf
dem LoxBerry und erledigt dort die Arbeit vor Ort: Kennzahlen der Miniserver
und des LoxBerry sammeln, Konfigurations-Backups ziehen, Aufträge des Partners
ausführen und auf dessen Anforderung einen zeitlich begrenzten Support-Tunnel
öffnen.

Der zugehörige Server läuft beim Systemintegrator und ist nicht Teil dieses
Repositories.

## Was der Client tut

| | |
|---|---|
| **Telemetrie** | Alle fünf Minuten Kennzahlen von den Miniservern und vom LoxBerry, im Minutentakt zum Server |
| **Backups** | Nach Zeitplan die Konfiguration der Miniserver über `fslist`/`fsget`, als ZIP (auf Wunsch AES-256), stückweise zum Server |
| **Aufträge** | Der Client fragt beim Poll, ob etwas anliegt — er nimmt keine Verbindung von außen an |
| **Support-Tunnel** | Auf Anforderung des Partners, zeitlich begrenzt, nur nach Prüfung eines Passworts, das der Betreiber selbst vergibt |

## Der Client baut keine Verbindung von außen auf

Es gibt keinen offenen Port und keinen Dienst, der auf Anfragen wartet. Der
Client fragt im Minutentakt beim Server nach, ob etwas zu tun ist, und
entscheidet dann selbst.

Für einen Support-Tunnel müssen **drei** Bedingungen gleichzeitig erfüllt sein:

1. Zugang zum Server — ohne ihn entsteht gar kein Auftrag
2. das Tunnel-Passwort — der Client prüft es gegen sein lokal abgelegtes
   Geheimnis; der Server kennt das Passwort **nie**
3. der Signaturschlüssel des Servers — der Client verwirft jeden unsignierten
   Auftrag

Das Tunnel-Passwort vergibt der Betreiber des LoxBerry selbst, in der
Plugin-Oberfläche. Es verlässt das Gerät nicht.

## Voraussetzungen

- **LoxBerry ab 4.0.0.16.** Ältere Versionen beenden beim „Remote-Support
  beenden" *alle* `cloudflared`-Prozesse, also auch den Support-Tunnel dieses
  Plugins. Das ist kein Sicherheitsproblem — der Tunnel geht zu, nicht auf —,
  aber die Verbindung bräche ohne erkennbaren Grund ab.
- Das Paket `libdata-password-zxcvbn-perl` wird bei der Installation
  automatisch nachgezogen.

## Installation

Über den Plugin-Installer von LoxBerry, mit dem ZIP-Archiv aus den
[Releases](../../releases).

Nach der Installation trägt man in der Plugin-Oberfläche den
Bereitstellungscode ein, den der Partner erzeugt hat. Danach meldet sich der
Standort selbstständig an und arbeitet im Minutentakt.

## Lizenz

Quelloffen einsehbar, aber nicht frei: Der Quelltext ist veröffentlicht, damit
nachvollziehbar ist, was auf dem eigenen LoxBerry läuft. Der Betrieb auf
eigenen und betreuten Installationen ist unentgeltlich erlaubt; Weitergabe,
Veränderung und die Übernahme von Quelltext sind es nicht. Einzelheiten in
[LICENSE](LICENSE).

Anfragen zu abweichenden Nutzungsrechten: info@smartfleetmanager.de
