import { AsobiClient } from "./client.js";
import type { Notification, NotificationListParams } from "./types.js";

const PREFIX = "/api/v1/notifications";

export class NotificationsApi {
  constructor(private client: AsobiClient) {}

  list(params?: NotificationListParams): Promise<Notification[]> {
    return this.client.get<Notification[]>(PREFIX, params as Record<string, unknown>);
  }

  markRead(id: string): Promise<Record<string, unknown>> {
    return this.client.put(`${PREFIX}/${id}/read`);
  }

  delete(id: string): Promise<void> {
    return this.client.delete(`${PREFIX}/${id}`);
  }
}
