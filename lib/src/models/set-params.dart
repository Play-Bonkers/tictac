import 'package:tictac/src/models/topic-description.dart';
import 'package:tictac/src/models/topic-subscription.dart';
import 'package:tictac/src/models/credential.dart';

class SetParams {
  TopicDescription? desc;
  TopicSubscription? sub;
  List<String>? tags;
  Credential? cred;

  SetParams({this.desc, this.sub, this.tags, this.cred});

  // Hand-written instead of @JsonSerializable: SubPacketData embeds the
  // SetParams instance directly in its toMap output, and the dart:convert
  // JSON encoder dispatches to toJson() on each value. Without this the
  // encoder fails with "Converting object to an encodable object failed:
  // Instance of 'SetParams'" the first time a non-null setParams is sent
  // — which became reachable once the {sub} packet stopped silently
  // dropping its set payload.
  Map<String, dynamic> toJson() {
    return {
      'desc': desc?.toJson(),
      'sub': sub?.toJson(),
      'tags': tags,
      'cred': cred?.toJson(),
    };
  }
}
