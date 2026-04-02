import { AsobiClient } from "./client.js";
import type { InventoryItem, ConsumeParams } from "./types.js";

const PREFIX = "/api/v1/inventory";

export class InventoryApi {
  constructor(private client: AsobiClient) {}

  list(): Promise<InventoryItem[]> {
    return this.client.get<InventoryItem[]>(PREFIX);
  }

  consume(params: ConsumeParams): Promise<Record<string, unknown>> {
    return this.client.post(`${PREFIX}/consume`, params);
  }
}
