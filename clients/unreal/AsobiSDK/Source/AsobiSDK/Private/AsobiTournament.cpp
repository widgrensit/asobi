#include "AsobiTournament.h"

void UAsobiTournament::Init(UAsobiClient* InClient)
{
	Client = InClient;
}

void UAsobiTournament::List(const FOnAsobiTournamentListResponse& Callback)
{
	Client->Get(TEXT("/api/v1/tournaments"),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiTournament> Tournaments;
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
								Tournaments.Add(UAsobiClient::ParseTournament(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Tournaments);
		}));
}

void UAsobiTournament::Get(const FString& TournamentId, const FOnAsobiTournamentResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/tournaments/%s"), *TournamentId),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			FAsobiTournament Tournament;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					Tournament = UAsobiClient::ParseTournament(Json);
				}
			}
			Callback.ExecuteIfBound(bSuccess, Tournament);
		}));
}

void UAsobiTournament::Join(const FString& TournamentId, const FOnAsobiResponse& Callback)
{
	Client->Post(FString::Printf(TEXT("/api/v1/tournaments/%s/join"), *TournamentId), nullptr, Callback);
}

void UAsobiTournament::GetNotifications(const FOnAsobiNotificationListResponse& Callback)
{
	Client->Get(TEXT("/api/v1/notifications"),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiNotification> Notifications;
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
								Notifications.Add(UAsobiClient::ParseNotification(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Notifications);
		}));
}

void UAsobiTournament::MarkNotificationRead(const FString& NotificationId, const FOnAsobiResponse& Callback)
{
	Client->Put(FString::Printf(TEXT("/api/v1/notifications/%s/read"), *NotificationId), nullptr, Callback);
}

void UAsobiTournament::DeleteNotification(const FString& NotificationId, const FOnAsobiResponse& Callback)
{
	Client->Delete(FString::Printf(TEXT("/api/v1/notifications/%s"), *NotificationId), Callback);
}
