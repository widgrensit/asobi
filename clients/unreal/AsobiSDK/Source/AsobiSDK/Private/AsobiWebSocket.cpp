#include "AsobiWebSocket.h"
#include "WebSocketsModule.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"

UAsobiWebSocket::UAsobiWebSocket()
{
}

void UAsobiWebSocket::Connect(const FString& Url)
{
	if (!FModuleManager::Get().IsModuleLoaded(TEXT("WebSockets")))
	{
		FModuleManager::Get().LoadModule(TEXT("WebSockets"));
	}

	WebSocket = FWebSocketsModule::Get().CreateWebSocket(Url, TEXT("ws"));

	WebSocket->OnConnected().AddLambda([this]()
	{
		OnConnected.Broadcast();
	});

	WebSocket->OnConnectionError().AddLambda([this](const FString& Error)
	{
		OnError.Broadcast(Error);
	});

	WebSocket->OnClosed().AddLambda([this](int32 StatusCode, const FString& Reason, bool bWasClean)
	{
		OnDisconnected.Broadcast(Reason);
	});

	WebSocket->OnMessage().AddLambda([this](const FString& Message)
	{
		HandleMessage(Message);
	});

	WebSocket->Connect();
}

void UAsobiWebSocket::Disconnect()
{
	if (WebSocket.IsValid() && WebSocket->IsConnected())
	{
		WebSocket->Close();
	}
}

bool UAsobiWebSocket::IsConnected() const
{
	return WebSocket.IsValid() && WebSocket->IsConnected();
}

void UAsobiWebSocket::Authenticate(const FString& Token)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("token"), Token);
	Send(TEXT("session.connect"), Payload);
}

void UAsobiWebSocket::SendHeartbeat()
{
	Send(TEXT("session.heartbeat"), nullptr);
}

void UAsobiWebSocket::SendMatchInput(const FString& DataJson)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);

	TSharedPtr<FJsonObject> DataObj;
	TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(DataJson);
	if (FJsonSerializer::Deserialize(Reader, DataObj) && DataObj.IsValid())
	{
		Payload->SetObjectField(TEXT("data"), DataObj);
	}

	Send(TEXT("match.input"), Payload);
}

void UAsobiWebSocket::JoinMatch(const FString& MatchId)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("match_id"), MatchId);
	Send(TEXT("match.join"), Payload);
}

void UAsobiWebSocket::LeaveMatch()
{
	Send(TEXT("match.leave"), nullptr);
}

void UAsobiWebSocket::MatchmakerAdd(const FString& Mode, const TArray<FString>& Party)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("mode"), Mode);

	TArray<TSharedPtr<FJsonValue>> PartyArr;
	for (const FString& P : Party)
	{
		PartyArr.Add(MakeShareable(new FJsonValueString(P)));
	}
	Payload->SetArrayField(TEXT("party"), PartyArr);

	Send(TEXT("matchmaker.add"), Payload);
}

void UAsobiWebSocket::MatchmakerRemove(const FString& TicketId)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("ticket_id"), TicketId);
	Send(TEXT("matchmaker.remove"), Payload);
}

void UAsobiWebSocket::ChatJoin(const FString& ChannelId)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("channel_id"), ChannelId);
	Send(TEXT("chat.join"), Payload);
}

void UAsobiWebSocket::ChatLeave(const FString& ChannelId)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("channel_id"), ChannelId);
	Send(TEXT("chat.leave"), Payload);
}

void UAsobiWebSocket::ChatSend(const FString& ChannelId, const FString& Content)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("channel_id"), ChannelId);
	Payload->SetStringField(TEXT("content"), Content);
	Send(TEXT("chat.send"), Payload);
}

void UAsobiWebSocket::UpdatePresence(const FString& Status)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("status"), Status);
	Send(TEXT("presence.update"), Payload);
}

void UAsobiWebSocket::CastVote(const FString& VoteId, const FString& OptionId)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("vote_id"), VoteId);
	Payload->SetStringField(TEXT("option_id"), OptionId);
	Send(TEXT("vote.cast"), Payload);
}

void UAsobiWebSocket::UseVeto(const FString& VoteId)
{
	TSharedPtr<FJsonObject> Payload = MakeShareable(new FJsonObject);
	Payload->SetStringField(TEXT("vote_id"), VoteId);
	Send(TEXT("vote.veto"), Payload);
}

void UAsobiWebSocket::Send(const FString& Type, const TSharedPtr<FJsonObject>& Payload)
{
	if (!WebSocket.IsValid() || !WebSocket->IsConnected())
	{
		return;
	}

	TSharedPtr<FJsonObject> Msg = MakeShareable(new FJsonObject);
	Msg->SetStringField(TEXT("type"), Type);
	Msg->SetNumberField(TEXT("cid"), NextCid++);

	if (Payload.IsValid())
	{
		Msg->SetObjectField(TEXT("payload"), Payload);
	}
	else
	{
		Msg->SetObjectField(TEXT("payload"), MakeShareable(new FJsonObject));
	}

	WebSocket->Send(SerializeJson(Msg));
}

void UAsobiWebSocket::HandleMessage(const FString& MessageString)
{
	TSharedPtr<FJsonObject> Json;
	TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(MessageString);
	if (!FJsonSerializer::Deserialize(Reader, Json) || !Json.IsValid())
	{
		return;
	}

	FString Type;
	Json->TryGetStringField(TEXT("type"), Type);

	const TSharedPtr<FJsonObject>* PayloadObj = nullptr;
	Json->TryGetObjectField(TEXT("payload"), PayloadObj);

	FString PayloadStr;
	if (PayloadObj && PayloadObj->IsValid())
	{
		PayloadStr = SerializeJson(*PayloadObj);
	}

	// Broadcast raw message
	OnMessage.Broadcast(Type, PayloadStr);

	// Dispatch typed events
	if (Type == TEXT("session.connected"))
	{
		// Handled by raw OnMessage
	}
	else if (Type == TEXT("session.heartbeat"))
	{
		// Handled by raw OnMessage
	}
	else if (Type == TEXT("match.state"))
	{
		OnMatchState.Broadcast(PayloadStr);
	}
	else if (Type.StartsWith(TEXT("match.")))
	{
		if (Type == TEXT("match.joined"))
		{
			OnMatchJoined.Broadcast(PayloadStr);
		}
		else if (Type == TEXT("match.left"))
		{
			OnMatchLeft.Broadcast();
		}
		else
		{
			FString Event = Type.Mid(6); // strip "match."
			OnMatchEvent.Broadcast(Event, PayloadStr);
		}
	}
	else if (Type == TEXT("matchmaker.queued"))
	{
		FString TicketId;
		if (PayloadObj && PayloadObj->IsValid())
		{
			(*PayloadObj)->TryGetStringField(TEXT("ticket_id"), TicketId);
		}
		OnMatchmakerQueued.Broadcast(TicketId);
	}
	else if (Type == TEXT("matchmaker.removed"))
	{
		OnMatchmakerRemoved.Broadcast();
	}
	else if (Type == TEXT("chat.message"))
	{
		FString ChannelId;
		if (PayloadObj && PayloadObj->IsValid())
		{
			(*PayloadObj)->TryGetStringField(TEXT("channel_id"), ChannelId);
		}
		OnChatReceived.Broadcast(ChannelId, PayloadStr);
	}
	else if (Type == TEXT("chat.joined"))
	{
		FString ChannelId;
		if (PayloadObj && PayloadObj->IsValid())
		{
			(*PayloadObj)->TryGetStringField(TEXT("channel_id"), ChannelId);
		}
		OnChatJoined.Broadcast(ChannelId);
	}
	else if (Type == TEXT("chat.left"))
	{
		FString ChannelId;
		if (PayloadObj && PayloadObj->IsValid())
		{
			(*PayloadObj)->TryGetStringField(TEXT("channel_id"), ChannelId);
		}
		OnChatLeft.Broadcast(ChannelId);
	}
	else if (Type == TEXT("notification.new"))
	{
		OnNotificationReceived.Broadcast(PayloadStr);
	}
	else if (Type == TEXT("presence.updated"))
	{
		FString Status;
		if (PayloadObj && PayloadObj->IsValid())
		{
			(*PayloadObj)->TryGetStringField(TEXT("status"), Status);
		}
		OnPresenceUpdated.Broadcast(Status);
	}
	else if (Type == TEXT("vote.cast_ok"))
	{
		OnVoteCastOk.Broadcast();
	}
	else if (Type == TEXT("vote.veto_ok"))
	{
		OnVoteVetoOk.Broadcast();
	}
}

FString UAsobiWebSocket::SerializeJson(const TSharedPtr<FJsonObject>& Obj)
{
	FString Output;
	TSharedRef<TJsonWriter<TCHAR, TCondensedJsonPrintPolicy<TCHAR>>> Writer =
		TJsonWriterFactory<TCHAR, TCondensedJsonPrintPolicy<TCHAR>>::Create(&Output);
	FJsonSerializer::Serialize(Obj.ToSharedRef(), Writer);
	return Output;
}
