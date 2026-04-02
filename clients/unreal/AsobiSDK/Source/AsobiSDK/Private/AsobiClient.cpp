#include "AsobiClient.h"
#include "HttpModule.h"
#include "Interfaces/IHttpResponse.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"

UAsobiClient::UAsobiClient()
	: BaseUrl(TEXT("http://localhost:8080"))
{
}

void UAsobiClient::SetBaseUrl(const FString& Url)
{
	BaseUrl = Url;
}

void UAsobiClient::SetAuthToken(const FString& Token)
{
	AuthToken = Token;
}

void UAsobiClient::SetRefreshToken(const FString& Token)
{
	RefreshToken = Token;
}

FString UAsobiClient::GetAuthToken() const
{
	return AuthToken;
}

FString UAsobiClient::GetPlayerId() const
{
	return PlayerId;
}

void UAsobiClient::SetPlayerId(const FString& Id)
{
	PlayerId = Id;
}

void UAsobiClient::Get(const FString& Path, const FOnAsobiResponse& Callback)
{
	SendRequest(TEXT("GET"), Path, TEXT(""), Callback);
}

void UAsobiClient::Post(const FString& Path, const TSharedPtr<FJsonObject>& Body, const FOnAsobiResponse& Callback)
{
	SendRequest(TEXT("POST"), Path, Body.IsValid() ? ToJsonString(Body) : TEXT("{}"), Callback);
}

void UAsobiClient::Put(const FString& Path, const TSharedPtr<FJsonObject>& Body, const FOnAsobiResponse& Callback)
{
	SendRequest(TEXT("PUT"), Path, Body.IsValid() ? ToJsonString(Body) : TEXT("{}"), Callback);
}

void UAsobiClient::Delete(const FString& Path, const FOnAsobiResponse& Callback)
{
	SendRequest(TEXT("DELETE"), Path, TEXT(""), Callback);
}

void UAsobiClient::SendRequest(const FString& Verb, const FString& Path, const FString& Body, const FOnAsobiResponse& Callback)
{
	FHttpModule& HttpModule = FHttpModule::Get();
	TSharedRef<IHttpRequest, ESPMode::ThreadSafe> Request = HttpModule.CreateRequest();

	Request->SetURL(BaseUrl + Path);
	Request->SetVerb(Verb);
	Request->SetHeader(TEXT("Content-Type"), TEXT("application/json"));
	Request->SetHeader(TEXT("Accept"), TEXT("application/json"));

	if (!AuthToken.IsEmpty())
	{
		Request->SetHeader(TEXT("Authorization"), FString::Printf(TEXT("Bearer %s"), *AuthToken));
	}

	if (!Body.IsEmpty() && (Verb == TEXT("POST") || Verb == TEXT("PUT")))
	{
		Request->SetContentAsString(Body);
	}

	Request->OnProcessRequestComplete().BindLambda(
		[Callback](FHttpRequestPtr Req, FHttpResponsePtr Resp, bool bConnected)
		{
			if (!bConnected || !Resp.IsValid())
			{
				Callback.ExecuteIfBound(false, TEXT(""));
				return;
			}

			bool bSuccess = Resp->GetResponseCode() >= 200 && Resp->GetResponseCode() < 300;
			Callback.ExecuteIfBound(bSuccess, Resp->GetContentAsString());
		});

	Request->ProcessRequest();
}

TSharedPtr<FJsonObject> UAsobiClient::ParseJson(const FString& JsonString)
{
	TSharedPtr<FJsonObject> JsonObject;
	TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(JsonString);
	FJsonSerializer::Deserialize(Reader, JsonObject);
	return JsonObject;
}

FString UAsobiClient::ToJsonString(const TSharedPtr<FJsonObject>& JsonObject)
{
	FString Output;
	TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Output);
	FJsonSerializer::Serialize(JsonObject.ToSharedRef(), Writer);
	return Output;
}

static FString GetStr(const TSharedPtr<FJsonObject>& Json, const FString& Key)
{
	FString Value;
	if (Json.IsValid())
	{
		Json->TryGetStringField(Key, Value);
	}
	return Value;
}

static int32 GetInt(const TSharedPtr<FJsonObject>& Json, const FString& Key, int32 Default = 0)
{
	int32 Value = Default;
	if (Json.IsValid())
	{
		Json->TryGetNumberField(Key, Value);
	}
	return Value;
}

static int64 GetInt64(const TSharedPtr<FJsonObject>& Json, const FString& Key, int64 Default = 0)
{
	double Value = static_cast<double>(Default);
	if (Json.IsValid() && Json->TryGetNumberField(Key, Value))
	{
		return static_cast<int64>(Value);
	}
	return Default;
}

static float GetFloat(const TSharedPtr<FJsonObject>& Json, const FString& Key, float Default = 0.0f)
{
	double Value = static_cast<double>(Default);
	if (Json.IsValid())
	{
		Json->TryGetNumberField(Key, Value);
	}
	return static_cast<float>(Value);
}

static bool GetBool(const TSharedPtr<FJsonObject>& Json, const FString& Key, bool Default = false)
{
	bool Value = Default;
	if (Json.IsValid())
	{
		Json->TryGetBoolField(Key, Value);
	}
	return Value;
}

FAsobiPlayer UAsobiClient::ParsePlayer(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiPlayer P;
	if (!Json.IsValid()) return P;
	P.Id = GetStr(Json, TEXT("id"));
	P.Username = GetStr(Json, TEXT("username"));
	P.DisplayName = GetStr(Json, TEXT("display_name"));
	P.AvatarUrl = GetStr(Json, TEXT("avatar_url"));
	P.InsertedAt = GetStr(Json, TEXT("inserted_at"));
	P.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return P;
}

FAsobiPlayerStats UAsobiClient::ParsePlayerStats(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiPlayerStats S;
	if (!Json.IsValid()) return S;
	S.PlayerId = GetStr(Json, TEXT("player_id"));
	S.GamesPlayed = GetInt(Json, TEXT("games_played"));
	S.Wins = GetInt(Json, TEXT("wins"));
	S.Losses = GetInt(Json, TEXT("losses"));
	S.Rating = GetFloat(Json, TEXT("rating"), 1500.0f);
	S.RatingDeviation = GetFloat(Json, TEXT("rating_deviation"), 350.0f);
	S.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return S;
}

FAsobiMatchRecord UAsobiClient::ParseMatchRecord(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiMatchRecord M;
	if (!Json.IsValid()) return M;
	M.Id = GetStr(Json, TEXT("id"));
	M.Mode = GetStr(Json, TEXT("mode"));
	M.Status = GetStr(Json, TEXT("status"));
	M.StartedAt = GetStr(Json, TEXT("started_at"));
	M.FinishedAt = GetStr(Json, TEXT("finished_at"));
	M.InsertedAt = GetStr(Json, TEXT("inserted_at"));

	const TArray<TSharedPtr<FJsonValue>>* PlayersArray;
	if (Json->TryGetArrayField(TEXT("players"), PlayersArray))
	{
		for (const auto& Val : *PlayersArray)
		{
			FString Str;
			if (Val->TryGetString(Str))
			{
				M.Players.Add(Str);
			}
		}
	}
	return M;
}

FAsobiWallet UAsobiClient::ParseWallet(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiWallet W;
	if (!Json.IsValid()) return W;
	W.Id = GetStr(Json, TEXT("id"));
	W.PlayerId = GetStr(Json, TEXT("player_id"));
	W.Currency = GetStr(Json, TEXT("currency"));
	W.Balance = GetInt64(Json, TEXT("balance"));
	W.InsertedAt = GetStr(Json, TEXT("inserted_at"));
	W.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return W;
}

FAsobiTransaction UAsobiClient::ParseTransaction(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiTransaction T;
	if (!Json.IsValid()) return T;
	T.Id = GetStr(Json, TEXT("id"));
	T.WalletId = GetStr(Json, TEXT("wallet_id"));
	T.Amount = GetInt64(Json, TEXT("amount"));
	T.BalanceAfter = GetInt64(Json, TEXT("balance_after"));
	T.Reason = GetStr(Json, TEXT("reason"));
	T.ReferenceType = GetStr(Json, TEXT("reference_type"));
	T.ReferenceId = GetStr(Json, TEXT("reference_id"));
	T.InsertedAt = GetStr(Json, TEXT("inserted_at"));
	return T;
}

FAsobiStoreListing UAsobiClient::ParseStoreListing(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiStoreListing L;
	if (!Json.IsValid()) return L;
	L.Id = GetStr(Json, TEXT("id"));
	L.ItemDefId = GetStr(Json, TEXT("item_def_id"));
	L.Currency = GetStr(Json, TEXT("currency"));
	L.Price = GetInt(Json, TEXT("price"));
	L.bActive = GetBool(Json, TEXT("active"), true);
	L.ValidFrom = GetStr(Json, TEXT("valid_from"));
	L.ValidUntil = GetStr(Json, TEXT("valid_until"));
	return L;
}

FAsobiPlayerItem UAsobiClient::ParsePlayerItem(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiPlayerItem I;
	if (!Json.IsValid()) return I;
	I.Id = GetStr(Json, TEXT("id"));
	I.ItemDefId = GetStr(Json, TEXT("item_def_id"));
	I.PlayerId = GetStr(Json, TEXT("player_id"));
	I.Quantity = GetInt(Json, TEXT("quantity"), 1);
	I.AcquiredAt = GetStr(Json, TEXT("acquired_at"));
	I.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return I;
}

FAsobiFriendship UAsobiClient::ParseFriendship(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiFriendship F;
	if (!Json.IsValid()) return F;
	F.Id = GetStr(Json, TEXT("id"));
	F.PlayerId = GetStr(Json, TEXT("player_id"));
	F.FriendId = GetStr(Json, TEXT("friend_id"));
	F.Status = GetStr(Json, TEXT("status"));
	F.InsertedAt = GetStr(Json, TEXT("inserted_at"));
	F.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return F;
}

FAsobiGroup UAsobiClient::ParseGroup(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiGroup G;
	if (!Json.IsValid()) return G;
	G.Id = GetStr(Json, TEXT("id"));
	G.Name = GetStr(Json, TEXT("name"));
	G.Description = GetStr(Json, TEXT("description"));
	G.MaxMembers = GetInt(Json, TEXT("max_members"), 50);
	G.bOpen = GetBool(Json, TEXT("open"));
	G.CreatorId = GetStr(Json, TEXT("creator_id"));
	G.InsertedAt = GetStr(Json, TEXT("inserted_at"));
	G.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return G;
}

FAsobiLeaderboardEntry UAsobiClient::ParseLeaderboardEntry(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiLeaderboardEntry E;
	if (!Json.IsValid()) return E;
	E.Id = GetStr(Json, TEXT("id"));
	E.LeaderboardId = GetStr(Json, TEXT("leaderboard_id"));
	E.PlayerId = GetStr(Json, TEXT("player_id"));
	E.Score = GetInt64(Json, TEXT("score"));
	E.SubScore = GetInt64(Json, TEXT("sub_score"));
	E.Rank = GetInt(Json, TEXT("rank"));
	E.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return E;
}

FAsobiCloudSave UAsobiClient::ParseCloudSave(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiCloudSave S;
	if (!Json.IsValid()) return S;
	S.Id = GetStr(Json, TEXT("id"));
	S.PlayerId = GetStr(Json, TEXT("player_id"));
	S.Slot = GetStr(Json, TEXT("slot"));
	S.Version = GetInt(Json, TEXT("version"), 1);
	S.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return S;
}

FAsobiStorageObject UAsobiClient::ParseStorageObject(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiStorageObject O;
	if (!Json.IsValid()) return O;
	O.Id = GetStr(Json, TEXT("id"));
	O.Collection = GetStr(Json, TEXT("collection"));
	O.Key = GetStr(Json, TEXT("key"));
	O.PlayerId = GetStr(Json, TEXT("player_id"));
	O.Version = GetInt(Json, TEXT("version"), 1);
	O.ReadPerm = GetStr(Json, TEXT("read_perm"));
	O.WritePerm = GetStr(Json, TEXT("write_perm"));
	O.UpdatedAt = GetStr(Json, TEXT("updated_at"));
	return O;
}

FAsobiTournament UAsobiClient::ParseTournament(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiTournament T;
	if (!Json.IsValid()) return T;
	T.Id = GetStr(Json, TEXT("id"));
	T.Name = GetStr(Json, TEXT("name"));
	T.LeaderboardId = GetStr(Json, TEXT("leaderboard_id"));
	T.MaxEntries = GetInt(Json, TEXT("max_entries"));
	T.Status = GetStr(Json, TEXT("status"));
	T.StartAt = GetStr(Json, TEXT("start_at"));
	T.EndAt = GetStr(Json, TEXT("end_at"));
	T.InsertedAt = GetStr(Json, TEXT("inserted_at"));
	return T;
}

FAsobiNotification UAsobiClient::ParseNotification(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiNotification N;
	if (!Json.IsValid()) return N;
	N.Id = GetStr(Json, TEXT("id"));
	N.PlayerId = GetStr(Json, TEXT("player_id"));
	N.Type = GetStr(Json, TEXT("type"));
	N.Subject = GetStr(Json, TEXT("subject"));
	N.bRead = GetBool(Json, TEXT("read"));
	N.SentAt = GetStr(Json, TEXT("sent_at"));
	return N;
}

FAsobiChatMessage UAsobiClient::ParseChatMessage(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiChatMessage M;
	if (!Json.IsValid()) return M;
	M.Id = GetStr(Json, TEXT("id"));
	M.ChannelType = GetStr(Json, TEXT("channel_type"));
	M.ChannelId = GetStr(Json, TEXT("channel_id"));
	M.SenderId = GetStr(Json, TEXT("sender_id"));
	M.Content = GetStr(Json, TEXT("content"));
	M.SentAt = GetStr(Json, TEXT("sent_at"));
	return M;
}

FAsobiVote UAsobiClient::ParseVote(const TSharedPtr<FJsonObject>& Json)
{
	FAsobiVote V;
	if (!Json.IsValid()) return V;
	V.Id = GetStr(Json, TEXT("id"));
	V.MatchId = GetStr(Json, TEXT("match_id"));
	V.Template = GetStr(Json, TEXT("template"));
	V.Method = GetStr(Json, TEXT("method"));
	V.Turnout = GetFloat(Json, TEXT("turnout"));
	V.EligibleCount = GetInt(Json, TEXT("eligible_count"));
	V.WindowMs = GetInt(Json, TEXT("window_ms"));
	V.OpenedAt = GetStr(Json, TEXT("opened_at"));
	V.ClosedAt = GetStr(Json, TEXT("closed_at"));
	V.InsertedAt = GetStr(Json, TEXT("inserted_at"));
	return V;
}
