import { AsobiClient } from "./client.js";
import type { ChatMessage, ChatHistoryParams } from "./types.js";

const PREFIX = "/api/v1/chat";

export class ChatApi {
  constructor(private client: AsobiClient) {}

  history(channelId: string, params?: ChatHistoryParams): Promise<ChatMessage[]> {
    return this.client.get<ChatMessage[]>(
      `${PREFIX}/${channelId}/history`,
      params as Record<string, unknown>,
    );
  }
}
