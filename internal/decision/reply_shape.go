package decision

import "github.com/AndrewDryga/responder/internal/replypolicy"

const handBackFloor = replypolicy.HandBackFloor

func ReplyShapeCorrection(trigger, lane, action, message string) string {
	return replypolicy.ReplyShapeCorrection(trigger, lane, action, message)
}

func RuntimeReplyShapeCorrection(trigger, lane, action, message string) string {
	return replypolicy.RuntimeReplyShapeCorrection(trigger, lane, action, message)
}
func ReplyWordBudget(trigger, lane string) int { return replypolicy.ReplyWordBudget(trigger, lane) }
func GreetingTrigger(trigger string) bool      { return replypolicy.GreetingTrigger(trigger) }
func RequestedDepth(trigger string) bool       { return replypolicy.RequestedDepth(trigger) }
func ProseWordCount(message string) int        { return replypolicy.ProseWordCount(message) }
func HandBackClosing(message string) string    { return replypolicy.HandBackClosing(message) }
