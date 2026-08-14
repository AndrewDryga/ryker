package localstate

import (
	"context"
	"io"
	"reflect"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/slackui"
)

const pacedTestChannel = "CPACED"

// channelPostingArgument classifies every method of slackui.API: which argument
// names the channel whose Slack message-posting budget the call spends, or -1
// when the call spends none of it.
//
// This map is the whole guard. A method added to slackui.API is missing from it
// and the test below fails, so the question "does this new write spend a
// channel's posting budget" has to be answered by whoever adds the write rather
// than discovered later from a rate-limit error. The answers are then checked
// against the wrapper's actual behavior, not taken on trust.
//
// The -1 entries are not all the same kind of thing, and the reasons matter:
//
//   - reads spend nothing that this pacer meters;
//   - conversations.invite, setTopic, pins.add, conversations.join and
//     conversations.create are workspace-tier methods that do not compete with
//     chat.postMessage for a channel's posting budget, and pacing a room's
//     replies behind them would delay answers to buy back budget nobody spent;
//   - views.publish is addressed to a person, not a channel — its second
//     argument is a user ID, and recording it would key the pacer by user and
//     cool a "channel" that does not exist.
var channelPostingArgument = map[string]int{
	"Post":          2,
	"PostBroadcast": 2,
	"PostEphemeral": 1,
	// chat.update, assistant.threads.setStatus and the file upload pair are
	// metered by workspace tier rather than per channel. They record anyway
	// because the delivery queue has always spent a channel slot on them, and
	// dropping that here would loosen pacing as a side effect of a change whose
	// whole point is to tighten it.
	"Update":      1,
	"SetStatus":   1,
	"SetProgress": 1,
	"UploadFile":  1,
	"Auth":        -1,
	// canvases.create, canvases.access.set and files.info are workspace-tier
	// methods that publish a document rather than a message. Nothing appears in
	// the channel until the card pointing at the canvas is posted, and that
	// post records for itself; pacing the room's replies behind a canvas would
	// delay answers to buy back budget nobody spent.
	"CreateCanvas":        -1,
	"CreateChannel":       -1,
	"FindChannelByName":   -1,
	"GetChannel":          -1,
	"Invite":              -1,
	"SetTopic":            -1,
	"Pin":                 -1,
	"PublishHome":         -1,
	"JoinChannel":         -1,
	"UserAllowed":         -1,
	"UserGroupMembers":    -1,
	"GetFile":             -1,
	"DownloadFile":        -1,
	"RecentMessages":      -1,
	"FindDeliveryMessage": -1,
	"FindDeliveryFile":    -1,
}

// A Slack write that spends a channel's posting budget must tell the pacer, and
// one that spends nothing must not.
//
// Before this, only the delivery queue recorded, so the pacer's picture of a
// channel was the queue's own traffic and twenty other call sites were
// invisible to it. Recording moved into the client so that no call site has to
// remember — and this test is what keeps that true as the client grows, by
// driving every method slackui.API declares rather than the seven that happen
// to matter today.
func TestEveryChannelPostingWriteRecordsAgainstThePacer(t *testing.T) {
	apiType := reflect.TypeOf((*slackui.API)(nil)).Elem()
	if apiType.NumMethod() == 0 {
		t.Fatal("slackui.API declares no methods; this guard would pass vacuously")
	}
	for name := range channelPostingArgument {
		if _, ok := apiType.MethodByName(name); !ok {
			t.Errorf(
				"channelPostingArgument classifies %q, which slackui.API no longer declares",
				name,
			)
		}
	}
	now := time.Date(2026, 8, 9, 12, 0, 0, 0, time.UTC)
	for index := range apiType.NumMethod() {
		name := apiType.Method(index).Name
		channelArgument, classified := channelPostingArgument[name]
		if !classified {
			t.Errorf(
				"slackui.API.%s is not classified in channelPostingArgument: say which "+
					"argument is the channel whose posting budget it spends, or -1 for none",
				name,
			)
			continue
		}
		slots := NewChannelWriteSlots(time.Minute)
		paced := PaceChannelWrites(&stubSlack{}, slots, func() time.Time { return now })
		callWithChannel(t, paced, name, channelArgument)
		cooling := slots.Cooling(now)
		switch {
		case channelArgument >= 0 && len(cooling) == 0:
			t.Errorf(
				"%s spends channel posting budget but recorded nothing; the queue will "+
					"pace against room this write already took",
				name,
			)
		case channelArgument >= 0 && (len(cooling) != 1 || cooling[0] != pacedTestChannel):
			t.Errorf("%s recorded %v, want just %q", name, cooling, pacedTestChannel)
		case channelArgument < 0 && len(cooling) != 0:
			t.Errorf(
				"%s recorded %v, but it spends no per-channel posting budget; pacing "+
					"replies behind it delays answers for nothing",
				name, cooling,
			)
		}
	}
}

// callWithChannel drives one slackui.API method through the pacer.
//
// A method that spends budget gets the channel in the argument it was
// classified under and empty strings everywhere else, so recording the wrong
// argument records the empty string and shows up as nothing recorded. A method
// that spends none gets the channel ID in every string argument, so recording
// any of them — a user ID, a message timestamp — is caught too.
func callWithChannel(t *testing.T, api slackui.API, name string, channelArgument int) {
	t.Helper()
	method := reflect.ValueOf(api).MethodByName(name)
	if !method.IsValid() {
		t.Fatalf("the paced client does not implement slackui.API.%s", name)
	}
	signature := method.Type()
	count := signature.NumIn()
	if signature.IsVariadic() {
		count--
	}
	args := make([]reflect.Value, count)
	for index := range count {
		argument := signature.In(index)
		switch {
		case index == 0:
			args[index] = reflect.ValueOf(context.Background())
		case index == channelArgument,
			channelArgument < 0 && argument.Kind() == reflect.String:
			args[index] = reflect.ValueOf(pacedTestChannel)
		default:
			args[index] = reflect.Zero(argument)
		}
	}
	method.Call(args)
}

// The optional capabilities the service reaches by type assertion have to find
// the real client, or every one of them silently turns itself off.
func TestPacedSlackUnwrapsToTheClientUnderneath(t *testing.T) {
	inner := &stubSlack{}
	paced := PaceChannelWrites(inner, NewChannelWriteSlots(time.Minute), time.Now)
	wrapper, ok := paced.(interface{ Unwrap() slackui.API })
	if !ok {
		t.Fatal("a paced Slack client cannot be unwrapped")
	}
	if wrapper.Unwrap() != slackui.API(inner) {
		t.Fatal("unwrapping a paced Slack client did not return the client it wraps")
	}
}

// stubSlack answers every slackui.API call with zero values. The subject here is
// the wrapper's bookkeeping, not the client's behavior; a method added to the
// interface stops this file compiling, which is the same alarm as a failing
// assertion.
type stubSlack struct{}

func (*stubSlack) Auth(context.Context) (slackui.Identity, error) {
	return slackui.Identity{}, nil
}

func (*stubSlack) CreateChannel(context.Context, string, bool, string) (slackui.Channel, error) {
	return slackui.Channel{}, nil
}

func (*stubSlack) FindChannelByName(context.Context, string, string) (slackui.Channel, error) {
	return slackui.Channel{}, nil
}

func (*stubSlack) GetChannel(context.Context, string) (slackui.Channel, error) {
	return slackui.Channel{}, nil
}

func (*stubSlack) Invite(context.Context, string, ...string) error { return nil }

func (*stubSlack) SetTopic(context.Context, string, string) error { return nil }

func (*stubSlack) Post(
	context.Context, string, string, string, slackui.Message,
) (string, error) {
	return "", nil
}

func (*stubSlack) PostBroadcast(
	context.Context, string, string, string, slackui.Message,
) (string, error) {
	return "", nil
}

func (*stubSlack) PostEphemeral(context.Context, string, string, slackui.Message) error {
	return nil
}

func (*stubSlack) Update(context.Context, string, string, slackui.Message) error { return nil }

func (*stubSlack) Pin(context.Context, string, string) error { return nil }

func (*stubSlack) SetStatus(context.Context, string, string, string) error { return nil }

func (*stubSlack) SetProgress(context.Context, string, string, string, []string) error {
	return nil
}

func (*stubSlack) PublishHome(context.Context, string, slackui.Message) error { return nil }

func (*stubSlack) CreateCanvas(context.Context, string, string, string) (string, error) {
	return "", nil
}

func (*stubSlack) JoinChannel(context.Context, string) error { return nil }

func (*stubSlack) UserAllowed(context.Context, string, string) (bool, error) { return false, nil }

func (*stubSlack) UserGroupMembers(context.Context, string, string) ([]string, error) {
	return nil, nil
}

func (*stubSlack) GetFile(context.Context, string) (slackui.HistoryFile, error) {
	return slackui.HistoryFile{}, nil
}

func (*stubSlack) DownloadFile(context.Context, string, io.Writer) error { return nil }

func (*stubSlack) UploadFile(
	context.Context, string, string, slackui.FileUpload,
) (slackui.FileDeliveryResult, error) {
	return slackui.FileDeliveryResult{}, nil
}

func (*stubSlack) RecentMessages(
	context.Context, string, string, string, string, int,
) ([]slackui.HistoryMessage, error) {
	return nil, nil
}

func (*stubSlack) FindDeliveryMessage(
	context.Context, string, string, string,
) (string, error) {
	return "", nil
}

func (*stubSlack) FindDeliveryFile(
	context.Context, string, string, string,
) (slackui.FileDeliveryResult, error) {
	return slackui.FileDeliveryResult{}, nil
}
