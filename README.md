# Logstash Plugin

This is a plugin for [Logstash](https://github.com/elasticsearch/logstash).

It is fully free and fully open source. The license is Apache 2.0, meaning you are pretty much free to use it however you want in whatever way.

## Documentation

The role of this codec plugin is to extract content out of compressed JSON telemetry streams produced by the network and carried over stream based transport (e.g. TCP).  A [sister plugin](https://github.com/cisco/logstash-codec-bigmuddy-network-telemetry-gpb) handles protobuf encoded content. The codec generates logstash events which can then be handled by the output stage using an output plugin which matches the consuming application. For example, logstash running with this plugin as input codec, might use;

- the [elasticsearch output plugin](https://github.com/logstash-plugins/logstash-output-elasticsearch) in order to push content in [elasticsearch](https://www.elastic.co/products/elasticsearch).
- a [transport output plugin](https://github.com/logstash-plugins/logstash-output-tcp) to push telemetry content into [Splunk](http://www.splunk.com/).
- the [Kafka output plugin](https://github.com/logstash-plugins/logstash-output-kafka) to publish telemetry content to an [Apache Kafka](http://kafka.apache.org/) bus and in to a big data platform.
- the [bigmuddy network telemetry metrics output plugin](https://github.com/cisco/logstash-output-bigmuddy-network-telemetry-metrics) to extract numeric metrics, and push them over HTTP to platforms like [prometheus](http://prometheus.io/) or [signalfx](https://signalfx.com/).

A collection of pre-packaged and pre-configured [container based stacks](https://github.com/cisco/bigmuddy-network-telemetry-stacks) should make access to a running setup (e.g ELK stack, prometheus stack, signalfx stack) easy.

Further documentation is provided in the [plugin source](/lib/logstash/codecs/telemetry.rb).

__Note: The streaming telemetry project is work in progress, and both the on and off box components of streaming telemetry are likely to evolve at a fast pace.__

## Massaging the content through configuration options

NOTE: The [container based stacks](https://github.com/cisco/bigmuddy-network-telemetry-stacks) contain sample configurations which may prove useful if you are looking for other examples.

The codec is expected to be used in conjunction with stream based transport protocols like `TCP`. The content handled by this codec is received in the form of TLV blocks where each block contains a compressed JSON tree. Each compressed JSON tree may contain multiple instances and types of data. 

Here is an example of one decompressed JSON block, exported using a policy configuration on the router specified as:

```
"Paths": [
"RootOper.InfraStatistics.Interface(*).Latest.GenericCounters",
"RootOper.InfraStatistics.Interface(*).Latest.DataRate"]
```

Decompressed JSON block containing multiple instances (`Null0` and `GigabitEthernet0/0/0/0`) and multiple types (`DataRate` and `GenericCounters`):

```
{
        "Policy" => "mypolicy",
       "Version" => 30,
    "Identifier" => "c2_e",
    "Start Time" => 1447774103808,
      "End Time" => 1447774103943,
          "Data" => {
        "RootOper" => {
            "InfraStatistics" => {
                                 "Null0" => {
                    "Latest" => {
                        "GenericCounters" => {
                                           "PacketsReceived" => 0,
                                             "BytesReceived" => 0,
                                               "PacketsSent" => 0,
                                                 "BytesSent" => 0,
,,,
                        },
                               "DataRate" => {
                                   "InputDataRate" => 0,
                                 "InputPacketRate" => 0,
                                  "OutputDataRate" => 0,
                                "OutputPacketRate" => 0,
...   
                     }
                    }
                },
                "GigabitEthernet0/0/0/0" => {
                    "Latest" => {
                        "GenericCounters" => {
                                           "PacketsReceived" => 21828063,
                                             "BytesReceived" => 1619994010,
                                               "PacketsSent" => 25465048,
                                                 "BytesSent" => 1902967400,
                        },
                               "DataRate" => {
                                   "InputDataRate" => 13,
                                 "InputPacketRate" => 22,
                                  "OutputDataRate" => 16,
                                "OutputPacketRate" => 28,
...
                        }
                    }
                },
...
    },
      "@version" => "1",
    "@timestamp" => "2015-11-17T15:28:23.971Z",
          "host" => "192.168.0.3",
}

```

Note that this output can be passed down the logstash pipeline to the filter stage as is. In order to do so, set the `xform` codec option to `xform => "raw"`.

It is also possible to flatten the decompressed JSON tree in to a number of events. A logstash event can be generated for each leaf in the input JSON tree. This would look as follows:

Codec configuration:

```
	codec => telemetry {
	    xform => "flat" 
	    xform_flat_delimeter => "~"
        }
```

The resulting events passed to the filter stage look like this:

```
{
           "path" => "DATA~RootOper~InfraStatistics~Null0~Latest~DataRate",
           "type" => "InputDataRate",
        "content" => 0,
     "identifier" => "c1_e",
    "policy_name" => "mypolicy",
        "version" => 30,
       "end_time" => 1447775098962,
       "@version" => "1",
     "@timestamp" => "2015-11-17T15:44:59.642Z",
           "host" => "26.26.26.2",
}
{
           "path" => "DATA~RootOper~InfraStatistics~Null0~Latest~DataRate",
           "type" => "OutputDataRate",
        "content" => 0,
     "identifier" => "c1_e",
    "policy_name" => "mypolicy",
        "version" => 30,
       "end_time" => 1447775098962,
       "@version" => "1",
     "@timestamp" => "2015-11-17T15:44:59.659Z",
           "host" => "26.26.26.2",
}

```

Finally, it is possible to configure the `xform_flat_keys` options in order to:

- determine the path down the JSON tree which should be considered an event, anything beneath the path is grouped into a single event.
- determine which components of the path should be extracted and setup as a key in the event (using named regular expressions)
- determine what the JSON substree should be called in the event

For a configuration of `xform_flat_keys` which looks like this:

```
	codec => telemetry {
	    xform => "flat" 
	        xform_flat_delimeter => "~"
		    xform_flat_keys => [
'counters', 'RootOper~InfraStatistics~(?<InterfaceName>.*)~Latest~GenericCounters',
'datarates', 'RootOper~InfraStatistics~(?<InterfaceName>.*)~Latest~DataRate']
	     }
```

an output event might look like this:

```
{
     "identifier" => "c1_e",
    "policy_name" => "mypolicy",
        "version" => 30,
       "end_time" => 1447772873953,
       "@version" => "1",
     "@timestamp" => "2015-11-17T15:07:54.007Z",
           "host" => "26.26.26.2",
           "path" => "DATA~RootOper~InfraStatistics~GigabitEthernet0/0/0/0~Latest~GenericCounters",
           "type" => "counters",
        "content" => {
        "counters" => {
                           "PacketsReceived" => 5547587,
                             "BytesReceived" => 521199697,
                               "PacketsSent" => 1843327,
                                 "BytesSent" => 133306750,
...
        },
             "key" => {
            "InterfaceName" => "GigabitEthernet0/0/0/0"
        }
    },

```

Note the extracted `key` field, and the name of the subtree and `type` field corresponding to the `counters` configuration.

Here is an example of an event generated for the `datarates` line in the configuration:

```
     "identifier" => "c1_e",
    "policy_name" => "mypolicy",
...
           "path" => "DATA~RootOper~InfraStatistics~GigabitEthernet0/0/0/0~Latest~DataRate",
           "type" => "datarates",
        "content" => {
        "datarates" => {
                   "InputDataRate" => 4,
                 "InputPacketRate" => 6,
                  "OutputDataRate" => 0,
...
        },
              "key" => {
            "InterfaceName" => "GigabitEthernet0/0/0/0"
        }
    },

```

Any JSON substrees which do not match any line in the `xform_flat_keys` will be flattened all the way to the leaf, as in the previous example.

Here is an example listing the full input side configuration in logstash:

```
input {
    tcp {
    port => 5555
    codec => telemetry {
        xform => "flat" 
	xform_flat_keys => [
'counters', 'RootOper~InfraStatistics~(?<InterfaceName>.*)~Latest~GenericCounters',
'datarates', 'RootOper~InfraStatistics~(?<InterfaceName>.*)~Latest~DataRate']
        }
    }
}
```

## Need Help?

Need help? Try #logstash on freenode IRC or the https://discuss.elastic.co/c/logstash discussion forum.

## Developing

### 1. Plugin Development and Testing

#### Code
- To get started, you'll need JRuby with the Bundler gem installed.

- Create a new plugin or clone and existing from the GitHub [logstash-plugins](https://github.com/logstash-plugins) organization. We also provide [example plugins](https://github.com/logstash-plugins?query=example).

- Install dependencies
```sh
bundle install
```

#### Test

- Update your dependencies

```sh
bundle install
```

- Run tests

```sh
bundle exec rspec
```

Unit test effort in progress.

### 2. Running your unpublished Plugin in Logstash

#### 2.1 Run in a local Logstash clone

- Edit Logstash `Gemfile` and add the local plugin path, for example:
```ruby
gem "logstash-codec-telemetry", :path => "/your/local/logstash-codec-telemetry"
```
- Install plugin
```sh
bin/plugin install --no-verify
```
- Run Logstash with your plugin
```sh
bin/logstash -e 'filter {awesome {}}'
```
At this point any modifications to the plugin code will be applied to this local Logstash setup. After modifying the plugin, simply rerun Logstash.

#### 2.2 Run in an installed Logstash

You can use the same **2.1** method to run your plugin in an installed Logstash by editing its `Gemfile` and pointing the `:path` to your local plugin development directory or you can build the gem and install it using:

- Build your plugin gem
```sh
gem build logstash-codec-telemetry.gemspec
```
- Install the plugin from the Logstash home
```sh
bin/plugin install /your/local/plugin/logstash-codec-telemetry.gem
```
- Start Logstash and proceed to test the plugin

## Contributing

All contributions are welcome: ideas, patches, documentation, bug reports, complaints, and even something you drew up on a napkin.

Programming is not a required skill. Whatever you've seen about open source and maintainers or community members  saying "send patches or die" - you will not see that here.

It is more important to the community that you are able to contribute.

For more information about contributing, see the [CONTRIBUTING](https://github.com/elasticsearch/logstash/blob/master/CONTRIBUTING.md) file.