import { AsobiClient } from "./client.js";
import type { SaveData, StorageItem, StorageListParams } from "./types.js";

const PREFIX = "/api/v1";

export class StorageApi {
  constructor(private client: AsobiClient) {}

  // Cloud Saves
  listSaves(): Promise<SaveData[]> {
    return this.client.get<SaveData[]>(`${PREFIX}/saves`);
  }

  getSave(slot: string): Promise<SaveData> {
    return this.client.get<SaveData>(`${PREFIX}/saves/${slot}`);
  }

  putSave(slot: string, data: Record<string, unknown>): Promise<SaveData> {
    return this.client.put<SaveData>(`${PREFIX}/saves/${slot}`, data);
  }

  // Generic Storage
  listStorage(collection: string, params?: StorageListParams): Promise<StorageItem[]> {
    return this.client.get<StorageItem[]>(
      `${PREFIX}/storage/${collection}`,
      params as Record<string, unknown>,
    );
  }

  getStorage(collection: string, key: string): Promise<StorageItem> {
    return this.client.get<StorageItem>(`${PREFIX}/storage/${collection}/${key}`);
  }

  putStorage(collection: string, key: string, value: Record<string, unknown>): Promise<StorageItem> {
    return this.client.put<StorageItem>(`${PREFIX}/storage/${collection}/${key}`, value);
  }

  deleteStorage(collection: string, key: string): Promise<void> {
    return this.client.delete(`${PREFIX}/storage/${collection}/${key}`);
  }
}
