#include "AsobiLeaderboard.h"

void UAsobiLeaderboard::Init(UAsobiClient* InClient)
{
	Client = InClient;
}

static TArray<FAsobiLeaderboardEntry> ParseEntries(const FString& Response)
{
	TArray<FAsobiLeaderboardEntry> Entries;
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
					Entries.Add(UAsobiClient::ParseLeaderboardEntry(*Obj));
				}
			}
		}
	}
	return Entries;
}

void UAsobiLeaderboard::GetTop(const FString& LeaderboardId, const FOnAsobiLeaderboardResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/leaderboards/%s"), *LeaderboardId),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiLeaderboardEntry> Entries;
			if (bSuccess)
			{
				Entries = ParseEntries(Response);
			}
			Callback.ExecuteIfBound(bSuccess, Entries);
		}));
}

void UAsobiLeaderboard::Submit(const FString& LeaderboardId, int64 Score, int64 SubScore, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetNumberField(TEXT("score"), static_cast<double>(Score));
	Body->SetNumberField(TEXT("sub_score"), static_cast<double>(SubScore));

	Client->Post(FString::Printf(TEXT("/api/v1/leaderboards/%s"), *LeaderboardId), Body, Callback);
}

void UAsobiLeaderboard::GetAround(const FString& LeaderboardId, const FString& PlayerId, const FOnAsobiLeaderboardResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/leaderboards/%s/around/%s"), *LeaderboardId, *PlayerId),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiLeaderboardEntry> Entries;
			if (bSuccess)
			{
				Entries = ParseEntries(Response);
			}
			Callback.ExecuteIfBound(bSuccess, Entries);
		}));
}

void UAsobiLeaderboard::GetMatchVotes(const FString& MatchId, const FOnAsobiResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/matches/%s/votes"), *MatchId), Callback);
}

void UAsobiLeaderboard::GetVote(const FString& VoteId, const FOnAsobiResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/votes/%s"), *VoteId), Callback);
}
