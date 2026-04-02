#pragma once

#include "CoreMinimal.h"
#include "AsobiClient.h"
#include "AsobiSocial.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiFriendListResponse, bool, bSuccess, const TArray<FAsobiFriendship>&, Friends);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiGroupResponse, bool, bSuccess, const FAsobiGroup&, Group);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiChatHistoryResponse, bool, bSuccess, const TArray<FAsobiChatMessage>&, Messages);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiSocial : public UObject
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void Init(UAsobiClient* InClient);

	// GET /api/v1/friends
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void GetFriends(const FOnAsobiFriendListResponse& Callback);

	// POST /api/v1/friends
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void AddFriend(const FString& FriendId, const FOnAsobiResponse& Callback);

	// PUT /api/v1/friends/:friend_id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void UpdateFriend(const FString& FriendId, const FString& Status, const FOnAsobiResponse& Callback);

	// DELETE /api/v1/friends/:friend_id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void RemoveFriend(const FString& FriendId, const FOnAsobiResponse& Callback);

	// POST /api/v1/groups
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void CreateGroup(const FString& Name, const FString& Description, int32 MaxMembers, bool bOpen, const FOnAsobiGroupResponse& Callback);

	// GET /api/v1/groups/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void GetGroup(const FString& GroupId, const FOnAsobiGroupResponse& Callback);

	// POST /api/v1/groups/:id/join
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void JoinGroup(const FString& GroupId, const FOnAsobiResponse& Callback);

	// POST /api/v1/groups/:id/leave
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void LeaveGroup(const FString& GroupId, const FOnAsobiResponse& Callback);

	// GET /api/v1/chat/:channel_id/history
	UFUNCTION(BlueprintCallable, Category = "Asobi|Social")
	void GetChatHistory(const FString& ChannelId, const FOnAsobiChatHistoryResponse& Callback);

private:
	UPROPERTY()
	UAsobiClient* Client = nullptr;
};
