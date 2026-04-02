import { AsobiClient } from "./client.js";
import type {
  Friend,
  AddFriendParams,
  UpdateFriendParams,
  Group,
  CreateGroupParams,
} from "./types.js";

const PREFIX = "/api/v1";

export class SocialApi {
  constructor(private client: AsobiClient) {}

  // Friends
  friends(): Promise<Friend[]> {
    return this.client.get<Friend[]>(`${PREFIX}/friends`);
  }

  addFriend(params: AddFriendParams): Promise<Friend> {
    return this.client.post<Friend>(`${PREFIX}/friends`, params);
  }

  updateFriend(friendId: string, params: UpdateFriendParams): Promise<Friend> {
    return this.client.put<Friend>(`${PREFIX}/friends/${friendId}`, params);
  }

  removeFriend(friendId: string): Promise<void> {
    return this.client.delete(`${PREFIX}/friends/${friendId}`);
  }

  // Groups
  createGroup(params: CreateGroupParams): Promise<Group> {
    return this.client.post<Group>(`${PREFIX}/groups`, params);
  }

  getGroup(id: string): Promise<Group> {
    return this.client.get<Group>(`${PREFIX}/groups/${id}`);
  }

  joinGroup(id: string): Promise<Record<string, unknown>> {
    return this.client.post(`${PREFIX}/groups/${id}/join`);
  }

  leaveGroup(id: string): Promise<Record<string, unknown>> {
    return this.client.post(`${PREFIX}/groups/${id}/leave`);
  }
}
