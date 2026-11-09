//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { necto } from "@necto/bridge";
import { HTTPExporter } from "@necto/http-exporter";

async function register() {
  await necto.registerExporter(new HTTPExporter({
    url: "https://collector.example.invalid/events",
  }));
}

void register().catch(() => {
  void necto.diagnostics.log("failure", "Could not register the HTTP exporter").catch(() => {});
});
