// Copyright (c) 2025, WSO2 LLC. (http://www.wso2.com).
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.
import ballerina/http;
import ballerinax/health.fhir.r5;
import ballerinax/health.fhir.r5.international500;

function init() {
    international500:initialize();
}

# Function to validate against API Config and parse FHIR resource payload.
#
# + payload - FHIR resource payload  
# + apiConfig - APIConfig of the FHIR resource API
# + return - Record representation of the FHIR resource if success.
public isolated function validateAndParse(json|xml payload, r5:ResourceAPIConfig apiConfig)
                                                            returns anydata|r5:FHIRValidationError|r5:FHIRParseError? {
    readonly & r5:Profile profile = check validateAndExtractProfile(payload, apiConfig);
    return check parseFHIRResource(profile, payload);
}

# Function to validate and parse FHIR resource payload.
#
# + payload - FHIR resource payload
# + targetFHIRModelType - (Optional) target model type to parse. Derived from payload if not given.
# + targetProfile - (Optional) target profile to parse. Derived from payload if not given.
# + return - Record representation of the FHIR resource if success. Otherwise, return validation error.
public isolated function parseWithValidation(json|xml|string payload, typedesc<anydata>? targetFHIRModelType = (), string? targetProfile = ())
                                                            returns anydata|r5:FHIRValidationError|r5:FHIRParseError {
    anydata parseResult = check parse(payload, targetFHIRModelType, targetProfile);
    check validate(parseResult);
    return parseResult;
}

# Function to parse FHIR Payload into FHIR Resource model.
# Note : When using inside FHIR templates, use ballerinax/health.fhir.r4.parser module instead of this.
#
# + payload - FHIR payload  
# + targetFHIRModelType - (Optional) target model type to parse. Derived from payload if not given  
# + targetProfile - (Optional) target profile to parse. Derived from payload if not given
# + return - returns FHIR model (Need to cast to relevant type by the caller). FHIRParseError if error ocurred
public isolated function parse(json|xml|string payload, typedesc<anydata>? targetFHIRModelType = (), string? targetProfile = ())
returns anydata|r5:FHIRParseError {
    json|xml _payload;
    if payload is string {
        json|error parsedJsonPayload = payload.fromJsonString();
        if parsedJsonPayload is json {
            _payload = parsedJsonPayload;
        } else {
            xml|error parsedXmlPayload = xml:fromString(payload);
            if parsedXmlPayload is xml:Element {
                _payload = parsedXmlPayload;
            } else {
                return <r5:FHIRParseError>r5:createFHIRError("Failed to parse string payload to json or xml", r5:ERROR,
                r5:INVALID_STRUCTURE, errorType = r5:PARSE_ERROR, httpStatusCode = http:STATUS_BAD_REQUEST);
            }
        }
    } else {
        _payload = payload;
    }

    string|r5:FHIRValidationError resourceType = extractResourceType(_payload);
    if resourceType is r5:FHIRValidationError {
        return <r5:FHIRParseError>r5:createParserErrorFrom(resourceType);
    }
    r5:Profile resourceProfile;
    if targetProfile != () {
        (r5:Profile & readonly)? profile = r5:fhirRegistry.findProfile(targetProfile);
        if profile is (r5:Profile & readonly) {
            resourceProfile = profile.clone();
        } else {
            string msg = string `Failed to find FHIR profile for the resource type : ${resourceType}`;
            return <r5:FHIRParseError>r5:createFHIRError(msg, r5:ERROR, r5:INVALID_STRUCTURE, errorType = r5:PARSE_ERROR,
            httpStatusCode = http:STATUS_BAD_REQUEST);
        }
    } else if targetFHIRModelType != () {
        r5:ResourceDefinitionRecord|r5:FHIRTypeError resourceDefinition = r5:getResourceDefinition(targetFHIRModelType);
        if resourceDefinition is r5:ResourceDefinitionRecord {
            string? profile = resourceDefinition.profile;
            if profile != () {
                map<r5:Profile & readonly> & readonly perResourceProfiles = r5:fhirRegistry.getResourceProfiles(resourceType);
                if perResourceProfiles.hasKey(profile) {
                    resourceProfile = perResourceProfiles.get(profile);
                } else {
                    string msg = string `Failed to find FHIR profile for the resource type : ${resourceType}`;
                    return <r5:FHIRParseError>r5:createFHIRError(msg, r5:ERROR, r5:INVALID_STRUCTURE, errorType =
                    r5:PARSE_ERROR, httpStatusCode = http:STATUS_BAD_REQUEST);
                }
            } else {
                string msg = string `Failed to find FHIR profile in the definition of the resource type : ${resourceType}`;
                return <r5:FHIRParseError>r5:createFHIRError(msg, r5:ERROR, r5:INVALID_STRUCTURE, errorType = r5:PARSE_ERROR,
                httpStatusCode = http:STATUS_BAD_REQUEST);
            }
        } else {
            return <r5:FHIRParseError>r5:createFHIRError(resourceDefinition.message(), r5:ERROR, r5:INVALID_STRUCTURE, errorType = r5:PARSE_ERROR,
            httpStatusCode = http:STATUS_BAD_REQUEST);
        }
    } else {
        string[]? payloadProfiles = extractProfiles(_payload);
        if payloadProfiles != () && payloadProfiles.length() > 0 {
            (r5:Profile & readonly)? profile = r5:fhirRegistry.findProfile(payloadProfiles[0]).clone();
            if profile is (r5:Profile & readonly) {
                resourceProfile = profile.clone();
            } else {
                string msg = "Failed to find FHIR profile for the profile URL : " + payloadProfiles[0];
                return <r5:FHIRParseError>r5:createFHIRError(msg, r5:ERROR, r5:INVALID_STRUCTURE, errorType = r5:PARSE_ERROR,
                httpStatusCode = http:STATUS_BAD_REQUEST);
            }
        } else {
            (r5:Profile & readonly)? profile = r5:fhirRegistry.findBaseProfile(resourceType);
            if profile is (r5:Profile & readonly) {
                resourceProfile = profile.clone();
            } else {
                string msg = "Failed to find FHIR profile for the resource type : " + resourceType;
                return <r5:FHIRParseError>r5:createFHIRError(msg, r5:ERROR, r5:INVALID_STRUCTURE, errorType = r5:PARSE_ERROR,
                httpStatusCode = http:STATUS_BAD_REQUEST);
            }
        }
    }
    return parseFHIRResource(resourceProfile, _payload);
}

isolated function validateAndExtractProfile(json|xml payload, r5:ResourceAPIConfig apiConfig)
                                                                    returns (readonly & r5:Profile)|r5:FHIRValidationError {
    string resourceType = check extractResourceType(payload);
    if !r5:fhirRegistry.isSupportedResource(resourceType) {
        string diag = string `Payload contains unknown resource type : ${resourceType}`;
        return <r5:FHIRValidationError>r5:createFHIRError("Unknown FHIR resource type", r5:ERROR, r5:INVALID, diag,
                                                errorType = r5:VALIDATION_ERROR, httpStatusCode = http:STATUS_BAD_REQUEST);
    }

    if resourceType != apiConfig.resourceType {
        string msg = "Mismatching resource type of the FHIR resource with the resource API";
        string diagMsg = string `Payload resource type : ${resourceType} but expected resource type : ${apiConfig.resourceType}`;
        return <r5:FHIRValidationError>r5:createFHIRError(msg, r5:ERROR, r5:INVALID, diagMsg,
                                                errorType = r5:VALIDATION_ERROR, httpStatusCode = http:STATUS_BAD_REQUEST);
    }

    string[]? profiles = extractProfiles(payload);
    if profiles != () && profiles.length() > 0 {
        map<r5:Profile & readonly> & readonly resourceProfiles = r5:fhirRegistry.getResourceProfiles(resourceType);
        // validate profiles
        foreach string profile in profiles {
            // check whether the profile is a valid profile
            if !resourceProfiles.hasKey(profile) {
                string diag = string `Unknown profile : ${profile}`;
                return <r5:FHIRValidationError>r5:createFHIRError("Invalid FHIR profile", r5:ERROR, r5:INVALID,
                                diagnostic = diag, errorType = r5:VALIDATION_ERROR, httpStatusCode = http:STATUS_BAD_REQUEST);
            }

            // check whether the profile is supported according to API config
            if apiConfig.profiles.indexOf(profile) is () {
                string diag = string `FHIR server does not support this FHIR profile : ${profile}`;
                return <r5:FHIRValidationError>r5:createFHIRError("Unsupported FHIR profile", r5:ERROR, r5:INVALID,
                                diagnostic = diag, errorType = r5:VALIDATION_ERROR, httpStatusCode = http:STATUS_BAD_REQUEST);
            }
        }

        // If there are multiple profiles, we select the matching default profile if configured
        // otherwise, default profile will be the base profile.
        string profile = profiles.length() == 1 ? profiles[0] : apiConfig.defaultProfile ?: "";
        if resourceProfiles.hasKey(profile) {
            return resourceProfiles.get(profile);
        }
    }
    // get base IG profile (we reach here if profile is not mentioned in the request or if the request contains multiple
    // resources with no default profile in API config)
    (r5:Profile & readonly)? profile = r5:fhirRegistry.findBaseProfile(resourceType);
    if profile != () {
        return profile;
    }
    string diag = string `Matching profile not found for the resource type : ${resourceType}`;
    return <r5:FHIRValidationError>r5:createFHIRError("Profile not found", r5:ERROR, r5:PROCESSING,
                                diagnostic = diag, errorType = r5:VALIDATION_ERROR, httpStatusCode = http:STATUS_BAD_REQUEST);

}

isolated function parseFHIRResource(r5:Profile profile, json|xml payload) returns anydata|r5:FHIRParseError {
    if payload is json {
        anydata|error cloneWithType = payload.cloneWithType(profile.modelType);
        if cloneWithType is error {
            string|error detailedMessage = cloneWithType.detail().get("message").ensureType(string);
            string diagnostic = detailedMessage is string ? detailedMessage : cloneWithType.detail().toString();
            return <r5:FHIRParseError>r5:createFHIRError("Failed to parse request body as JSON resource", r5:ERROR, r5:PROCESSING,
                                                    diagnostic, cause = cloneWithType, errorType = r5:PARSE_ERROR,
                                                    httpStatusCode = http:STATUS_BAD_REQUEST);
        } else {
            return cloneWithType;
        }
    } else {
        // TODO: parse xml payload [https://github.com/wso2-enterprise/open-healthcare/issues/887]
        return <r5:FHIRParseError>r5:createFHIRError("XML format of FHIR resources not supported yet", r5:ERROR,
                                                r5:PROCESSING_NOT_SUPPORTED, errorType = r5:PARSE_ERROR,
                                                httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }
}

isolated function extractProfiles(json|xml payload) returns string[]? {
    if payload is json {
        json|error profiles = payload?.meta?.profile;
        if profiles is json[] {
            string[] result = [];
            foreach json profile in profiles {
                if profile is string {
                    result.push(profile);
                }
            }
            return result;
        }
    } else {
        // TODO handle XML payload [https://github.com/wso2-enterprise/open-healthcare/issues/887]
    }
    return ();
}

isolated function extractResourceType(json|xml payload) returns string|r5:FHIRValidationError {
    if payload is json {
        map<json> jsonPayload = <map<json>>payload;
        if jsonPayload.hasKey("resourceType") {
            json jResourceType = jsonPayload.get("resourceType");
            if jResourceType is string {
                return jResourceType;
            }
        }

    } else {
        // TODO handle XML payload [https://github.com/wso2-enterprise/open-healthcare/issues/887]
        return <r5:FHIRValidationError>r5:createFHIRError("XML format of FHIR resources not supported yet", r5:ERROR,
                                                r5:PROCESSING_NOT_SUPPORTED, errorType = r5:VALIDATION_ERROR,
                                                httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }
    string message = "Failed to parse request body as JSON resource";
    string diagnostic = "Invalid JSON content detected, missing required element: \"resourceType\"";
    return <r5:FHIRValidationError>r5:createFHIRError(message, r5:ERROR, r5:PROCESSING, diagnostic = diagnostic,
                                errorType = r5:VALIDATION_ERROR, httpStatusCode = http:STATUS_BAD_REQUEST);
}
