#pragma once

#include "CoreMinimal.h"
#include "Http.h"
#include "AsobiTypes.h"
#include "AsobiClient.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiResponse, bool, bSuccess, const FString&, ResponseBody);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiClient : public UObject
{
	GENERATED_BODY()

public:
	UAsobiClient();

	UFUNCTION(BlueprintCallable, Category = "Asobi")
	void SetBaseUrl(const FString& Url);

	UFUNCTION(BlueprintCallable, Category = "Asobi")
	void SetAuthToken(const FString& Token);

	UFUNCTION(BlueprintCallable, Category = "Asobi")
	void SetRefreshToken(const FString& Token);

	UFUNCTION(BlueprintPure, Category = "Asobi")
	FString GetAuthToken() const;

	UFUNCTION(BlueprintPure, Category = "Asobi")
	FString GetPlayerId() const;

	void SetPlayerId(const FString& Id);

	// HTTP helpers
	void Get(const FString& Path, const FOnAsobiResponse& Callback);
	void Post(const FString& Path, const TSharedPtr<FJsonObject>& Body, const FOnAsobiResponse& Callback);
	void Put(const FString& Path, const TSharedPtr<FJsonObject>& Body, const FOnAsobiResponse& Callback);
	void Delete(const FString& Path, const FOnAsobiResponse& Callback);

	// Parse helpers
	static TSharedPtr<FJsonObject> ParseJson(const FString& JsonString);
	static FString ToJsonString(const TSharedPtr<FJsonObject>& JsonObject);

	// Type parsing
	static FAsobiPlayer ParsePlayer(const TSharedPtr<FJsonObject>& Json);
	static FAsobiPlayerStats ParsePlayerStats(const TSharedPtr<FJsonObject>& Json);
	static FAsobiMatchRecord ParseMatchRecord(const TSharedPtr<FJsonObject>& Json);
	static FAsobiWallet ParseWallet(const TSharedPtr<FJsonObject>& Json);
	static FAsobiTransaction ParseTransaction(const TSharedPtr<FJsonObject>& Json);
	static FAsobiStoreListing ParseStoreListing(const TSharedPtr<FJsonObject>& Json);
	static FAsobiPlayerItem ParsePlayerItem(const TSharedPtr<FJsonObject>& Json);
	static FAsobiFriendship ParseFriendship(const TSharedPtr<FJsonObject>& Json);
	static FAsobiGroup ParseGroup(const TSharedPtr<FJsonObject>& Json);
	static FAsobiLeaderboardEntry ParseLeaderboardEntry(const TSharedPtr<FJsonObject>& Json);
	static FAsobiCloudSave ParseCloudSave(const TSharedPtr<FJsonObject>& Json);
	static FAsobiStorageObject ParseStorageObject(const TSharedPtr<FJsonObject>& Json);
	static FAsobiTournament ParseTournament(const TSharedPtr<FJsonObject>& Json);
	static FAsobiNotification ParseNotification(const TSharedPtr<FJsonObject>& Json);
	static FAsobiChatMessage ParseChatMessage(const TSharedPtr<FJsonObject>& Json);
	static FAsobiVote ParseVote(const TSharedPtr<FJsonObject>& Json);

private:
	void SendRequest(const FString& Verb, const FString& Path, const FString& Body, const FOnAsobiResponse& Callback);

	FString BaseUrl;
	FString AuthToken;
	FString RefreshToken;
	FString PlayerId;
};
