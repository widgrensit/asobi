#include "AsobiMatchmaker.h"

void UAsobiMatchmaker::Init(UAsobiClient* InClient)
{
	Client = InClient;
}

void UAsobiMatchmaker::Add(const FString& Mode, const TArray<FString>& Party, const FOnAsobiMatchmakerResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("mode"), Mode);

	TArray<TSharedPtr<FJsonValue>> PartyArr;
	for (const FString& P : Party)
	{
		PartyArr.Add(MakeShareable(new FJsonValueString(P)));
	}
	Body->SetArrayField(TEXT("party"), PartyArr);

	Client->Post(TEXT("/api/v1/matchmaker"), Body,
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			FAsobiMatchmakerTicket Ticket;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					Json->TryGetStringField(TEXT("ticket_id"), Ticket.TicketId);
					Json->TryGetStringField(TEXT("status"), Ticket.Status);
				}
			}
			Callback.ExecuteIfBound(bSuccess, Ticket);
		}));
}

void UAsobiMatchmaker::Status(const FString& TicketId, const FOnAsobiMatchmakerResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/matchmaker/%s"), *TicketId),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			FAsobiMatchmakerTicket Ticket;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					Json->TryGetStringField(TEXT("ticket_id"), Ticket.TicketId);
					Json->TryGetStringField(TEXT("status"), Ticket.Status);
				}
			}
			Callback.ExecuteIfBound(bSuccess, Ticket);
		}));
}

void UAsobiMatchmaker::Remove(const FString& TicketId, const FOnAsobiResponse& Callback)
{
	Client->Delete(FString::Printf(TEXT("/api/v1/matchmaker/%s"), *TicketId), Callback);
}
