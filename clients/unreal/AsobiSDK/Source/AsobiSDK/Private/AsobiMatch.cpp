#include "AsobiMatch.h"

void UAsobiMatch::Init(UAsobiClient* InClient)
{
	Client = InClient;
}

void UAsobiMatch::List(const FOnAsobiMatchListResponse& Callback)
{
	Client->Get(TEXT("/api/v1/matches"),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiMatchRecord> Matches;
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
								Matches.Add(UAsobiClient::ParseMatchRecord(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Matches);
		}));
}

void UAsobiMatch::Get(const FString& MatchId, const FOnAsobiMatchResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/matches/%s"), *MatchId),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			FAsobiMatchRecord Match;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					Match = UAsobiClient::ParseMatchRecord(Json);
				}
			}
			Callback.ExecuteIfBound(bSuccess, Match);
		}));
}

void UAsobiMatch::GetPlayer(const FString& PlayerId, const FOnAsobiResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/players/%s"), *PlayerId), Callback);
}

void UAsobiMatch::UpdatePlayer(const FString& PlayerId, const FString& DisplayName, const FString& AvatarUrl, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	if (!DisplayName.IsEmpty())
	{
		Body->SetStringField(TEXT("display_name"), DisplayName);
	}
	if (!AvatarUrl.IsEmpty())
	{
		Body->SetStringField(TEXT("avatar_url"), AvatarUrl);
	}

	Client->Put(FString::Printf(TEXT("/api/v1/players/%s"), *PlayerId), Body, Callback);
}
