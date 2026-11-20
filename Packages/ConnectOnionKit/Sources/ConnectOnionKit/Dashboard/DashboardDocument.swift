import Foundation

/// Port of build-srcdoc.ts from oo-chat web, from Android oochat

/// Colour palette tokens injected as CSS variables (`--cc-*`) into the dashboard wrapper.
/// placeholder until real colour palette created
public struct DashboardThemePalette: Equatable, Sendable {
    public let canvas: String
    public let surface: String
    public let text: String
    public let muted: String
    public let border: String
    public let focus: String
    public let accent: String
    public let success: String
    public let warning: String
    public let danger: String

    public init(
        canvas: String,
        surface: String,
        text: String,
        muted: String,
        border: String,
        focus: String,
        accent: String,
        success: String,
        warning: String,
        danger: String
    ) {
        self.canvas = canvas
        self.surface = surface
        self.text = text
        self.muted = muted
        self.border = border
        self.focus = focus
        self.accent = accent
        self.success = success
        self.warning = warning
        self.danger = danger
    }

    public static let lightDefault = DashboardThemePalette(
        canvas: "#f7f8f6",
        surface: "#ffffff",
        text: "#171a17",
        muted: "#505650",
        border: "#d9ddd7",
        focus: "#075985",
        accent: "#14733a",
        success: "#14733a",
        warning: "#8a4b08",
        danger: "#b42318"
    )

    public static let darkDefault = DashboardThemePalette(
        canvas: "#111411",
        surface: "#191d19",
        text: "#f1f5f1",
        muted: "#bbc4bb",
        border: "#343b34",
        focus: "#7dd3fc",
        accent: "#62d68a",
        success: "#62d68a",
        warning: "#f7b955",
        danger: "#ff8a80"
    )
}

/// Light and dark colour sets for the dashboard document.
public struct DashboardColours: Equatable, Sendable {
    public let light: DashboardThemePalette
    public let dark: DashboardThemePalette

    public init(
        light: DashboardThemePalette = .lightDefault,
        dark: DashboardThemePalette = .darkDefault
    ) {
        self.light = light
        self.dark = dark
    }

    public static let `default` = DashboardColours()
}

/// Builds the owned HTML wrapper for agent-authored Control Center dashboards.
public enum DashboardDocument {
    /// Default `WKScriptMessageHandler` name for WKwebview
    public static let defaultMessageHandlerName = "ochat"

    private static let cspDirectives = [
        "default-src 'none'",
        "style-src 'unsafe-inline'",
        "img-src data:",
        "font-src data:"
    ]

    /// Builds the `<meta http-equiv="Content-Security-Policy" ...>` tag for the given nonce.
    public static func cspMeta(nonce: String) -> String {
        let directives = cspDirectives + ["script-src 'nonce-\(nonce)'"]
        let content = directives.joined(separator: "; ")
        return #"<meta http-equiv="Content-Security-Policy" content="\#(content)">"#
    }

    /// Builds the `<style>` block with theme colour variables, Dynamic Type font scaling,
    /// and styles for `co-filter` and `co-table` (`co-chart` is omitted as per Android implementation).
    public static func componentStyles(
        colours: DashboardColours = .default,
        fontScale: Double = 1.0
    ) -> String {
        let clampedScale = max(0.5, min(fontScale, 3.0))
        let percentage = Int((clampedScale * 100.0).rounded())

        return """
        <style>
        /* O Chat owns the Control Center component contract. Agent pages may keep their
           existing layout, while bridge-owned controls share one accessible token set. */
        :root {
          color-scheme: light dark;
          font-size: \(percentage)%;
          -webkit-text-size-adjust: \(percentage)%;
          --cc-font-scale: \(clampedScale);
          --cc-canvas: \(colours.light.canvas);
          --cc-surface: \(colours.light.surface);
          --cc-text: \(colours.light.text);
          --cc-muted: \(colours.light.muted);
          --cc-border: \(colours.light.border);
          --cc-focus: \(colours.light.focus);
          --cc-accent: \(colours.light.accent);
          --cc-success: \(colours.light.success);
          --cc-warning: \(colours.light.warning);
          --cc-danger: \(colours.light.danger);
          --cc-radius: 10px;
          --cc-space: 12px;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --cc-canvas: \(colours.dark.canvas);
            --cc-surface: \(colours.dark.surface);
            --cc-text: \(colours.dark.text);
            --cc-muted: \(colours.dark.muted);
            --cc-border: \(colours.dark.border);
            --cc-focus: \(colours.dark.focus);
            --cc-accent: \(colours.dark.accent);
            --cc-success: \(colours.dark.success);
            --cc-warning: \(colours.dark.warning);
            --cc-danger: \(colours.dark.danger);
          }
        }
        co-filter { display: block; margin: 0 0 12px; }
        co-filter input {
          width: 100%; box-sizing: border-box;
          min-height: 44px; padding: 9px 11px; border: 1px solid var(--cc-border); border-radius: var(--cc-radius);
          font: inherit; color: var(--cc-text); background: var(--cc-surface);
        }
        co-filter input:focus-visible { outline: 3px solid var(--cc-focus); outline-offset: 2px; }
        co-filter [data-ochat-count] { display: block; margin-top: 6px; color: var(--cc-muted); font-size: .85em; }
        [data-ochat-hidden] { display: none !important; }

        co-table { display: none; }
        [data-ochat-sortable] th[data-ochat-sort] { cursor: pointer; user-select: none; }
        [data-ochat-sortable] th[data-ochat-sort]:focus-visible { outline: 3px solid var(--cc-focus); outline-offset: 2px; }
        [data-ochat-sortable] th[data-ochat-sort]::after {
          content: ''; opacity: .35; margin-left: .4em; font-size: .85em;
        }
        [data-ochat-sortable] th[aria-sort="ascending"]::after { content: '\\2191'; opacity: .9; }
        [data-ochat-sortable] th[aria-sort="descending"]::after { content: '\\2193'; opacity: .9; }
        @media (prefers-reduced-motion: reduce) {
          *, *::before, *::after { animation: none !important; transition: none !important; }
        }
        </style>
        """
    }

    /// Builds the `<script nonce="...">` tag containing the click bridge, `co-filter`, and `co-table`.
    public static func bridgeScript(
        nonce: String,
        messageHandlerName: String = defaultMessageHandlerName
    ) -> String {
        // Note: Using a raw multiline string #""" ... """# so JS backslashes like /[,%$\s]/g
        // are emitted literally without double-escaping.
        return #"""
        <script nonce="\#(nonce)">
        document.addEventListener('click', function (e) {
          var t = e.target;
          var el = t && t.closest ? t.closest('[data-ochat-skill]') : null;
          if (el) {
            e.preventDefault();
            // passes skills to webkit to be render in wkwebview
            var payload = {
              type: 'ochat:skill',
              skill: el.getAttribute('data-ochat-skill'),
              args: el.getAttribute('data-ochat-args') || ''
            };
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\#(messageHandlerName)) {
              window.webkit.messageHandlers.\#(messageHandlerName).postMessage(payload);
            }
            return;
          }
          var a = t && t.closest ? t.closest('a[href]') : null;
          if (a && (a.getAttribute('href') || '').charAt(0) !== '#') e.preventDefault();
        });

        // <co-filter target="#skills" placeholder="Filter skills"> — the agent declares
        // that a list is filterable; we render the control and do the filtering.
        function ochatFilter(host) {
          if (host.getAttribute('data-ochat-ready')) return;
          var target = document.querySelector(host.getAttribute('target') || '');
          // A filter with nothing to filter looks like a working control and does
          // nothing. Render only when the target is real.
          if (!target) return;
          host.setAttribute('data-ochat-ready', '1');

          var input = document.createElement('input');
          input.type = 'search';
          // Set as a property, never as markup: this is agent-authored text.
          input.placeholder = host.getAttribute('placeholder') || 'Filter';
          input.setAttribute('aria-label', input.placeholder);

          var count = document.createElement('span');
          count.setAttribute('data-ochat-count', '1');
          count.setAttribute('aria-live', 'polite');

          host.textContent = '';
          host.appendChild(input);
          host.appendChild(count);

          var items = [];
          for (var i = 0; i < target.children.length; i++) items.push(target.children[i]);

          function apply() {
            var q = input.value.trim().toLowerCase();
            var shown = 0;
            for (var i = 0; i < items.length; i++) {
              var hit = !q || (items[i].textContent || '').toLowerCase().indexOf(q) !== -1;
              if (hit) { items[i].removeAttribute('data-ochat-hidden'); shown++; }
              else { items[i].setAttribute('data-ochat-hidden', '1'); }
            }
            // Silent until something is typed: a count answers a question the user
            // has not asked yet.
            count.textContent = q ? (shown + ' of ' + items.length) : '';
          }

          input.addEventListener('input', apply);
          apply();
        }

        // <co-table target="#runs"> — the agent declares that a table is sortable; we
        // make its headers controls. The column type is inferred rather than declared:
        // the cells already say what they are.
        function ochatTable(host) {
          if (host.getAttribute('data-ochat-ready')) return;
          var table = document.querySelector(host.getAttribute('target') || '');
          if (!table || !table.tHead || !table.tBodies.length) return;
          host.setAttribute('data-ochat-ready', '1');
          table.setAttribute('data-ochat-sortable', '1');

          var body = table.tBodies[0];
          var headers = table.tHead.rows.length ? table.tHead.rows[0].cells : [];

          function sortBy(index, dir) {
            var rows = [];
            for (var i = 0; i < body.rows.length; i++) rows.push(body.rows[i]);
            // Read every cell once, before sorting: a comparator that re-reads the
            // DOM on each comparison is where a few hundred rows get slow.
            var keyed = rows.map(function (row) {
              var cell = row.cells[index];
              return { row: row, text: (cell ? cell.textContent : '') || '' };
            });
            var numeric = keyed.every(function (k) {
              return k.text.trim() === '' || !isNaN(parseFloat(k.text.replace(/[,%$\s]/g, '')));
            });
            keyed.sort(function (a, b) {
              var cmp;
              if (numeric) {
                cmp = parseFloat(a.text.replace(/[,%$\s]/g, '') || '0')
                    - parseFloat(b.text.replace(/[,%$\s]/g, '') || '0');
              } else {
                // localeCompare so 'B' sorts after 'a', which is what a reader expects.
                cmp = a.text.trim().toLowerCase().localeCompare(b.text.trim().toLowerCase());
              }
              return dir === 'descending' ? -cmp : cmp;
            });
            for (var j = 0; j < keyed.length; j++) body.appendChild(keyed[j].row);

            for (var h = 0; h < headers.length; h++) {
              if (h === index) headers[h].setAttribute('aria-sort', dir);
              else headers[h].removeAttribute('aria-sort');
            }
          }

          for (var c = 0; c < headers.length; c++) {
            (function (index) {
              var th = headers[index];
              th.setAttribute('data-ochat-sort', '1');
              th.setAttribute('tabindex', '0');
              th.setAttribute('role', 'button');
              th.addEventListener('click', function () {
                var next = th.getAttribute('aria-sort') === 'ascending'
                  ? 'descending' : 'ascending';
                sortBy(index, next);
              });
            })(c);
          }
        }

        function ochatComponents() {
          var filters = document.querySelectorAll('co-filter');
          for (var i = 0; i < filters.length; i++) ochatFilter(filters[i]);
          var tables = document.querySelectorAll('co-table');
          for (var j = 0; j < tables.length; j++) ochatTable(tables[j]);
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', ochatComponents);
        } else {
          ochatComponents();
        }
        </script>
        """#
    }

    /// Wraps agent-authored HTML in a controlled document with a fresh per-render nonce.
    public static func buildSrcDoc(
        html: String,
        nonce: String = generateNonce(),
        colours: DashboardColours = .default,
        fontScale: Double = 1.0,
        messageHandlerName: String = defaultMessageHandlerName
    ) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(cspMeta(nonce: nonce))
        \(componentStyles(colours: colours, fontScale: fontScale))
        \(bridgeScript(nonce: nonce, messageHandlerName: messageHandlerName))
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }

    /// Generates a fresh 16-byte (32-character hex) cryptographic nonce on each call.
    public static func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
