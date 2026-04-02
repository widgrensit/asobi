import { AsobiClient } from "./client.js";
import type { Player, UpdatePlayerParams } from "./types.js";

const PREFIX = "/api/v1/players";

export class PlayersApi {
  constructor(private client: AsobiClient) {}

  get(id: string): Promise<Player> {
    return this.client.get<Player>(`${PREFIX}/${id}`);
  }

  update(id: string, params: UpdatePlayerParams): Promise<Player> {
    return this.client.put<Player>(`${PREFIX}/${id}`, params);
  }
}
