#include "AsobiSocial.h"

void UAsobiSocial::Init(UAsobiClient* InClient)
{
	Client = InClient;
}

void UAsobiSocial::GetFriends(const FOnAsobiFriendListResponse& Callback)
{
	Client->Get(TEXT("/api/v1/friends"),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiFriendship> Friends;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					const TArray<TSharedPtr<FJsonValue>>* DataArray;
					if (Json->TryGetArrayField(TEXT("data"), DataArray))
					{
						for (const auto& Val : *DataArray)
						{
							const TSharedPtr<FJsonObject>* Obj;
							if (Val->TryGetObject(Obj))
							{
								Friends.Add(UAsobiClient::ParseFriendship(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Friends);
		}));
}

void UAsobiSocial::AddFriend(const FString& FriendId, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("friend_id"), FriendId);

	Client->Post(TEXT("/api/v1/friends"), Body, Callback);
}

void UAsobiSocial::UpdateFriend(const FString& FriendId, const FString& Status, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("status"), Status);

	Client->Put(FString::Printf(TEXT("/api/v1/friends/%s"), *FriendId), Body, Callback);
}

void UAsobiSocial::RemoveFriend(const FString& FriendId, const FOnAsobiResponse& Callback)
{
	Client->Delete(FString::Printf(TEXT("/api/v1/friends/%s"), *FriendId), Callback);
}

void UAsobiSocial::CreateGroup(const FString& Name, const FString& Description, int32 MaxMembers, bool bOpen, const FOnAsobiGroupResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("name"), Name);
	if (!Description.IsEmpty())
	{
		Body->SetStringField(TEXT("description"), Description);
	}
	Body->SetNumberField(TEXT("max_members"), MaxMembers);
	Body->SetBoolField(TEXT("open"), bOpen);

	Client->Post(TEXT("/api/v1/groups"), Body,
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			FAsobiGroup Group;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					Group = UAsobiClient::ParseGroup(Json);
				}
			}
			Callback.ExecuteIfBound(bSuccess, Group);
		}));
}

void UAsobiSocial::GetGroup(const FString& GroupId, const FOnAsobiGroupResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/groups/%s"), *GroupId),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			FAsobiGroup Group;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					Group = UAsobiClient::ParseGroup(Json);
				}
			}
			Callback.ExecuteIfBound(bSuccess, Group);
		}));
}

void UAsobiSocial::JoinGroup(const FString& GroupId, const FOnAsobiResponse& Callback)
{
	Client->Post(FString::Printf(TEXT("/api/v1/groups/%s/join"), *GroupId), nullptr, Callback);
}

void UAsobiSocial::LeaveGroup(const FString& GroupId, const FOnAsobiResponse& Callback)
{
	Client->Post(FString::Printf(TEXT("/api/v1/groups/%s/leave"), *GroupId), nullptr, Callback);
}

void UAsobiSocial::GetChatHistory(const FString& ChannelId, const FOnAsobiChatHistoryResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/chat/%s/history"), *ChannelId),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiChatMessage> Messages;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					const TArray<TSharedPtr<FJsonValue>>* DataArray;
					if (Json->TryGetArrayField(TEXT("data"), DataArray))
					{
						for (const auto& Val : *DataArray)
						{
							const TSharedPtr<FJsonObject>* Obj;
							if (Val->TryGetObject(Obj))
							{
								Messages.Add(UAsobiClient::ParseChatMessage(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Messages);
		}));
}
