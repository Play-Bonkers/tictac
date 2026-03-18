import 'package:tictac/src/models/topic-names.dart' as topic_names;
import 'package:tictac/src/models/topic-subscription.dart';
import 'package:tictac/src/models/get-query.dart';
import 'package:tictac/src/services/logger.dart';
import 'package:tictac/src/services/tinode.dart';
import 'package:tictac/src/topic-me.dart';
import 'package:tictac/src/topic.dart';

class MetaGetBuilder {
  late TinodeService _tinodeService;
  late LoggerService _loggerService;

  late Topic topic;
  TopicSubscription? contact;
  Map<String, dynamic> what = {};

  MetaGetBuilder(Topic parent) {
    final services = parent.services;
    if (services != null) {
      _tinodeService = services.tinode;
      _loggerService = services.logger;
    }

    topic = parent;
    var me = _tinodeService.getTopic(topic_names.TOPIC_ME) as TopicMe?;

    if (me != null) {
      if (parent.name != null) {
        contact = me.getContact(parent.name!);
      }
    }
  }

  DateTime _getIms() {
    var cupd = contact != null ? contact?.updated : null;
    var tupd = topic.lastDescUpdate;
    return tupd.isAfter(cupd!) ? cupd : tupd;
  }

  MetaGetBuilder withData(int? since, int? before, int? limit) {
    what['data'] = {'since': since, 'before': before, 'limit': limit};
    return this;
  }

  MetaGetBuilder withLaterData(int? limit) {
    if (topic.maxSeq <= 0) {
      return this;
    }
    return withData((topic.maxSeq > 0 ? topic.maxSeq + 1 : null)!, null, limit);
  }

  MetaGetBuilder withEarlierData(int limit) {
    return withData(null, (topic.minSeq > 0 ? topic.minSeq : null)!, limit);
  }

  MetaGetBuilder withDesc(DateTime? ims) {
    what['desc'] = {'ims': ims};
    return this;
  }

  MetaGetBuilder withLaterDesc() {
    return withDesc(_getIms());
  }

  MetaGetBuilder withSub(DateTime? ims, int? limit, String? userOrTopic) {
    var opts = {'ims': ims, 'limit': limit};
    if (topic.getType() == 'me') {
      opts['topic'] = userOrTopic;
    } else {
      opts['user'] = userOrTopic;
    }
    what['sub'] = opts;
    return this;
  }

  MetaGetBuilder withOneSub(DateTime? ims, String? userOrTopic) {
    return withSub(ims, null, userOrTopic);
  }

  MetaGetBuilder withLaterOneSub(String? userOrTopic) {
    return withOneSub(topic.lastSubsUpdate, userOrTopic);
  }

  MetaGetBuilder withLaterSub(int? limit) {
    var ims = topic.isP2P() ? _getIms() : topic.lastSubsUpdate;
    return withSub(ims, limit, null);
  }

  MetaGetBuilder withTags() {
    what['tags'] = true;
    return this;
  }

  MetaGetBuilder withCred() {
    if (topic.getType() == 'me') {
      what['cred'] = true;
    } else {
      _loggerService.error('Invalid topic type for MetaGetBuilder:withCreds ' + topic.getType().toString());
    }
    return this;
  }

  MetaGetBuilder withDel(int? since, int? limit) {
    if (since != null || limit != null) {
      what['del'] = {'since': since, 'limit': limit};
    }
    return this;
  }

  MetaGetBuilder withLaterDel(int limit) {
    return withDel((topic.maxSeq > 0 ? topic.maxDel + 1 : null)!, limit);
  }

  GetQuery build() {
    var what = [];
    Map<String, dynamic>? params = <String, dynamic>{};
    ['data', 'sub', 'desc', 'tags', 'cred', 'del'].forEach((key) {
      if (this.what.containsKey(key)) {
        what.add(key);
        params![key] = this.what[key];
      }
    });
    if (what.isNotEmpty) {
      params['what'] = what.join(' ');
    } else {
      params = null;
    }
    return GetQuery.fromMessage(params ?? {});
  }
}
