import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:intl/intl.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart';
import 'package:HaltonBusAPI/HaltonBusAPI.dart';

///URL to resource/website which bus delay information is retrieved from. Only English is supported (for now)
const reportResource = "https://geoquery.haltonbus.ca/rss/Transportation-en-CA.xml";
///URL to resource/website where the general notice about major delays and/or cancellations are posted.
const generalNoticeResource = "https://geoquery.haltonbus.ca/Cancellations.aspx";
const generalNoticeResourceID = "ctl00_CPHPageBody_GeneralNoticesMsg";
///Index in raw data ([String]) of [reportResource]'s XML where data starts to be relevant and properly formatted (in XML)
const payloadStart = 3;

/**
 * API which interfaces with https://haltonbus.ca/, specifically [reportResource], to
 * provide information on bus delays in Halton District School Board. This API mainly acts
 * as a wrapper to formulate easy, organized, optimized, and relevant access to the bus reports.
 * 
 * DISCLAIMER: if the [reportResource] is down, this library MAY NOT FUNCTION CORRECTLY
 */
class BusAPI {
  ///global BusAPI instance, there can only be ONE
  static BusAPI _instance;
  ///caches, refreshed every ~4 minutes
  _Cache<XmlDocument> _delayCache;
  _Cache<String> _statusCache;
  ///List of all schools apart of the HDSB or HCDSB transportation system
  List<String> schoolNames;
  ///Singleton, which returns [_instance] on call, or lazy initializes it if null
  factory BusAPI() {
    return (_instance ??= new BusAPI._internal());
  }
  ///internal constructor used by [BusAPI]'s Singleton
  BusAPI._internal();

  /**
   * Returns a raw [xml.XmlDocument] straight from [reportResource]
   * This method does NOT cache it's results
  **/
  Future<XmlDocument> reqRaw() async {
    var response = await http.get(reportResource);
    return parse(response.body.substring(payloadStart));
  }

  /**
   * Returns a non-growable/immutable list of [Delay] objects for each transportation delay which is reported
   * This method uses [_cache] to retrieve its information, limiting the amount of requests
   * to a maximum of once every 4 minutes. Takes an optional parameter [invalidate] to force-replenish the cache of delays with
   * updated data.
   */
  Future<List<Delay>> latest({invalidate = false}) async {
    _delayCache?.invalidated = invalidate;
    if(_delayCache == null || _delayCache.isExpired()) {
      _delayCache = new _Cache(await reqRaw());
    }
    return _delayCache.response.findAllElements("item")
        .map((el) => new Delay(el.text)).toList(growable: false);
  }


  /**
   * Returns the current general transportation status for HDSB and HCDSB in the form of a [String]
   * Takes an optional parameter [invalidate] to force-replenish the cached status with
   * the updated one.
   * This method also stores the list of HDSB and HCDSB schools in [schoolNames] the first time it is invoked
   */
  Future<String> currentStatus({invalidate = false}) async {
    _statusCache?.invalidated = invalidate;
    if(_statusCache == null || _statusCache.isExpired()) {
      http.Response pageResponse = await http.get(generalNoticeResource);
      Document page = await html.parse(pageResponse.body);
      if(_statusCache == null) {
        final schoolDropdown = page.getElementById("ctl00_CPHPageBody_operatorSchoolFilter_schoolList");
        schoolNames = schoolDropdown.children
            .map((child) => child.innerHtml)
            .where((school) => school != "--All--")
            .toList(growable: false);
      }
      _statusCache = new _Cache(page.getElementById(generalNoticeResourceID).innerHtml);
    }
    return _statusCache.response;
  }

  /**
   * Retrieves the latest 'lastBuildDate', which is meant to be the last time the
   * [reportResource] report was updated. Note, this will return null if the cache is empty (meaning
   * [latest] was never called)
   */
  reportLastUpdated() => new DateFormat("EEE, dd MMM yyyy hh:mm:ss zzz")
      .parse(_delayCache?.response?.findAllElements("lastBuildDate")?.first?.text);

}

/**
 * Caches an XML response from [reportResource] for [lifeDuration]
 * milliseconds until needing to be replaced. This is put in to prevent redundant
 * uses of resources and time, as cache can be accessed instead of a costly new request
 */
class _Cache<T> {
  ///Duration until cache expires
  static const lifeDuration = 240000;
  ///Time (since Epoch) of cache creation
  final _timestamp;
  ///Where the requested document ([reportResource]) is stored
  final T response;

  bool invalidated = false;

  /**
   * Constructs a new cache, setting the [_timestamp] to the current time
   */
  _Cache(this.response) : _timestamp = new DateTime.now().millisecondsSinceEpoch;

  /**
   * Returns a [bool],
   * true => cache is expired, needs to be replaced
   * false => cache is relevant/safe to use
   */
  isExpired() => invalidated || ((_timestamp+lifeDuration) < DateTime.now().millisecondsSinceEpoch);
}
