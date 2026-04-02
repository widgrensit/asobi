#pragma once

#include "CoreMinimal.h"
#include "AsobiClient.h"
#include "AsobiLeaderboard.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiLeaderboardResponse, bool, bSuccess, const TArray<FAsobiLeaderboardEntry>&, Entries);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiLeaderboard : public UObject
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Asobi|Leaderboard")
	void Init(UAsobiClient* InClient);

	// GET /api/v1/leaderboards/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Leaderboard")
	void GetTop(const FString& LeaderboardId, const FOnAsobiLeaderboardResponse& Callback);

	// POST /api/v1/leaderboards/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Leaderboard")
	void Submit(const FString& LeaderboardId, int64 Score, int64 SubScore, const FOnAsobiResponse& Callback);

	// GET /api/v1/leaderboards/:id/around/:player_id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Leaderboard")
	void GetAround(const FString& LeaderboardId, const FString& PlayerId, const FOnAsobiLeaderboardResponse& Callback);

	// GET /api/v1/matches/:id/votes
	UFUNCTION(BlueprintCallable, Category = "Asobi|Leaderboard")
	void GetMatchVotes(const FString& MatchId, const FOnAsobiResponse& Callback);

	// GET /api/v1/votes/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Leaderboard")
	void GetVote(const FString& VoteId, const FOnAsobiResponse& Callback);

private:
	UPROPERTY()
	UAsobiClient* Client = nullptr;
};
