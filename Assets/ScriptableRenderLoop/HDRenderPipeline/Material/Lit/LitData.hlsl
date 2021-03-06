//-------------------------------------------------------------------------------------
// Fill SurfaceData/Builtin data function
//-------------------------------------------------------------------------------------
#include "../MaterialUtilities.hlsl"
#include "../SampleLayer.hlsl"

void GetBuiltinData(FragInputs input, SurfaceData surfaceData, float alpha, float depthOffset, out BuiltinData builtinData)
{
    // Builtin Data
    builtinData.opacity = alpha;

    // TODO: Sample lightmap/lightprobe/volume proxy
    // This should also handle projective lightmap
    // Note that data input above can be use to sample into lightmap (like normal)
    builtinData.bakeDiffuseLighting = SampleBakedGI(input.positionWS, surfaceData.normalWS, input.texCoord1, input.texCoord2);

    // Emissive Intensity is only use here, but is part of BuiltinData to enforce UI parameters as we want the users to fill one color and one intensity
    builtinData.emissiveIntensity = _EmissiveIntensity; // We still store intensity here so we can reuse it with debug code

    // If we chose an emissive color, we have a dedicated texture for it and don't use MaskMap
#ifdef _EMISSIVE_COLOR
#ifdef _EMISSIVE_COLOR_MAP
    builtinData.emissiveColor = SAMPLE_TEXTURE2D(_EmissiveColorMap, sampler_EmissiveColorMap, input.texCoord0).rgb * _EmissiveColor * builtinData.emissiveIntensity;
#else
    builtinData.emissiveColor = _EmissiveColor * builtinData.emissiveIntensity;
#endif
// If we have a MaskMap, use emissive slot as a mask on baseColor
#elif defined(_MASKMAP) && !defined(LAYERED_LIT_SHADER) // With layered lit we have no emissive mask option
    builtinData.emissiveColor = surfaceData.baseColor * (SAMPLE_TEXTURE2D(_MaskMap, sampler_MaskMap, input.texCoord0).b * builtinData.emissiveIntensity).xxx;
#else
    builtinData.emissiveColor = float3(0.0, 0.0, 0.0);
#endif

    builtinData.velocity = float2(0.0, 0.0);

#ifdef _DISTORTION_ON
    float3 distortion = SAMPLE_TEXTURE2D(_DistortionVectorMap, sampler_DistortionVectorMap, input.texCoord0).rgb;
    builtinData.distortion = distortion.rg;
    builtinData.distortionBlur = distortion.b;
#else
    builtinData.distortion = float2(0.0, 0.0);
    builtinData.distortionBlur = 0.0;
#endif

    builtinData.depthOffset = depthOffset;
}

struct LayerTexCoord
{
#ifndef LAYERED_LIT_SHADER
    LayerUV base;
    LayerUV details;
#else
    // Regular texcoord
    LayerUV base0;
    LayerUV base1;
    LayerUV base2;
    LayerUV base3;

    LayerUV details0;
    LayerUV details1;
    LayerUV details2;
    LayerUV details3;
#endif

    // triplanar weight
    float3 weights;
};

#ifndef LAYERED_LIT_SHADER

// include LitDataInternal to define GetSurfaceData
#define LAYER_INDEX 0
#define ADD_IDX(Name) Name
#define ADD_ZERO_IDX(Name) Name
#include "LitDataInternal.hlsl"

void GetLayerTexCoord(float2 texCoord0, float2 texCoord1, float2 texCoord2, float2 texCoord3,
                      float3 positionWS, float3 normalWS, out LayerTexCoord layerTexCoord)
{
    ZERO_INITIALIZE(LayerTexCoord, layerTexCoord);

#ifdef _MAPPING_TRIPLANAR
    // one weight for each direction XYZ - Use vertex normal for triplanar
    layerTexCoord.weights = ComputeTriplanarWeights(normalWS);
#endif

    // Be sure that the compiler is aware that we don't touch UV1 to UV3 for base layer in case of non layer shader
    // so it can remove code
    _UVMappingMask.yzw = float3(0.0, 0.0, 0.0);
    bool isTriplanar = false;
#ifdef _MAPPING_TRIPLANAR
    isTriplanar = true;
#endif
    ComputeLayerTexCoord(   texCoord0, texCoord1, texCoord2, texCoord3, 
                            positionWS, normalWS, isTriplanar, layerTexCoord);
}

void ApplyPerPixelDisplacement(FragInputs input, float3 V, inout LayerTexCoord layerTexCoord)
{
#if defined(_HEIGHTMAP) && defined(_PER_PIXEL_DISPLACEMENT)

    // ref: https://www.gamedev.net/resources/_/technical/graphics-programming-and-theory/a-closer-look-at-parallax-occlusion-mapping-r3262
    float3 viewDirTS = TransformWorldToTangent(V, input.tangentToWorld);
    // Change the number of samples per ray depending on the viewing angle for the surface. 
    // Oblique angles require  smaller step sizes to achieve more accurate precision for computing displacement.
    int numSteps = (int)lerp(_PPDMaxSamples, _PPDMinSamples, viewDirTS.z);

    ParallaxOcclusionMappingLayer(layerTexCoord, numSteps, viewDirTS);

    // TODO: We are supposed to modify lightmaps coordinate (fetch in GetBuiltin), but this isn't the same uv mapping, so can't apply the offset here...
    // Let's assume it will be "fine" as indirect diffuse is often low frequency
#endif
}

// Calculate displacement for per vertex displacement mapping
float ComputePerVertexDisplacement(LayerTexCoord layerTexCoord, float4 vertexColor, float lod)
{
    return SampleHeightmapLod(layerTexCoord, lod);
}

void GetSurfaceAndBuiltinData(FragInputs input, float3 V, inout PositionInputs posInput, out SurfaceData surfaceData, out BuiltinData builtinData)
{
    LayerTexCoord layerTexCoord;
    GetLayerTexCoord(input.texCoord0, input.texCoord1, input.texCoord2, input.texCoord3,
                     input.positionWS, input.tangentToWorld[2].xyz, layerTexCoord);


    ApplyPerPixelDisplacement(input, V, layerTexCoord);
    float depthOffset = 0.0;

#ifdef _DEPTHOFFSET_ON
    ApplyDepthOffsetPositionInput(V, depthOffset, posInput);
#endif

    // We perform the conversion to world of the normalTS outside of the GetSurfaceData
    // so it allow us to correctly deal with detail normal map and optimize the code for the layered shaders
    float3 normalTS;
    float alpha = GetSurfaceData(input, layerTexCoord, surfaceData, normalTS);
    GetNormalAndTangentWS(input, V, normalTS, surfaceData.normalWS, surfaceData.tangentWS);
    // Done one time for all layered - cumulate with spec occ alpha for now
    surfaceData.specularOcclusion *= GetHorizonOcclusion(V, surfaceData.normalWS, input.tangentToWorld[2].xyz, _HorizonFade);

    // Caution: surfaceData must be fully initialize before calling GetBuiltinData
    GetBuiltinData(input, surfaceData, alpha, depthOffset, builtinData);
}

#else

#define ADD_ZERO_IDX(Name) Name##0

// include LitDataInternal multiple time to define the variation of GetSurfaceData for each layer
#define LAYER_INDEX 0
#define ADD_IDX(Name) Name##0
#include "LitDataInternal.hlsl"
#undef LAYER_INDEX
#undef ADD_IDX

#define LAYER_INDEX 1
#define ADD_IDX(Name) Name##1
#include "LitDataInternal.hlsl"
#undef LAYER_INDEX
#undef ADD_IDX

#define LAYER_INDEX 2
#define ADD_IDX(Name) Name##2
#include "LitDataInternal.hlsl"
#undef LAYER_INDEX
#undef ADD_IDX

#define LAYER_INDEX 3
#define ADD_IDX(Name) Name##3
#include "LitDataInternal.hlsl"
#undef LAYER_INDEX
#undef ADD_IDX

void ComputeMaskWeights(float4 inputMasks, out float outWeights[_MAX_LAYER])
{
    float masks[_MAX_LAYER];
#if defined(_DENSITY_MODE)
    masks[0] = inputMasks.a;
#else
    masks[0] = 1.0;
#endif
    masks[1] = inputMasks.r;
    masks[2] = inputMasks.g;
    masks[3] = inputMasks.b;

    // calculate weight of each layers
    // Algorithm is like this:
    // Top layer have priority on others layers
    // If a top layer doesn't use the full weight, the remaining can be use by the following layer.
    float weightsSum = 0.0;

    [unroll]
    for (int i = _LAYER_COUNT - 1; i >= 0; --i)
    {
        outWeights[i] = min(masks[i], (1.0 - weightsSum));
        weightsSum = saturate(weightsSum + masks[i]);
    }
}

float3 BlendLayeredVector3(float3 x0, float3 x1, float3 x2, float3 x3, float weight[4])
{
    float3 result = float3(0.0, 0.0, 0.0);

    result = x0 * weight[0] + x1 * weight[1];
#if _LAYER_COUNT >= 3
    result += (x2 * weight[2]);
#endif
#if _LAYER_COUNT >= 4
    result += x3 * weight[3];
#endif

    return result;
}

float BlendLayeredScalar(float x0, float x1, float x2, float x3, float weight[4])
{
    float result = 0.0;

    result = x0 * weight[0] + x1 * weight[1];
#if _LAYER_COUNT >= 3
    result += x2 * weight[2];
#endif
#if _LAYER_COUNT >= 4
    result += x3 * weight[3];
#endif

    return result;
}

#define SURFACEDATA_BLEND_VECTOR3(surfaceData, name, mask) BlendLayeredVector3(surfaceData##0.##name, surfaceData##1.##name, surfaceData##2.##name, surfaceData##3.##name, mask);
#define SURFACEDATA_BLEND_SCALAR(surfaceData, name, mask) BlendLayeredScalar(surfaceData##0.##name, surfaceData##1.##name, surfaceData##2.##name, surfaceData##3.##name, mask);
#define PROP_BLEND_SCALAR(name, mask) BlendLayeredScalar(name##0, name##1, name##2, name##3, mask);

void GetLayerTexCoord(float2 texCoord0, float2 texCoord1, float2 texCoord2, float2 texCoord3,
                      float3 positionWS, float3 normalWS, out LayerTexCoord layerTexCoord)
{
    ZERO_INITIALIZE(LayerTexCoord, layerTexCoord);

#if defined(_LAYER_MAPPING_TRIPLANAR_0) || defined(_LAYER_MAPPING_TRIPLANAR_1) || defined(_LAYER_MAPPING_TRIPLANAR_2) || defined(_LAYER_MAPPING_TRIPLANAR_3)
    // one weight for each direction XYZ - Use vertex normal for triplanar
    layerTexCoord.weights = ComputeTriplanarWeights(normalWS);
#endif

    bool isTriplanar = false;
#ifdef _LAYER_MAPPING_TRIPLANAR_0
    isTriplanar = true;
#endif
    ComputeLayerTexCoord0(  texCoord0, texCoord1, texCoord2, texCoord3, 
                            positionWS, normalWS, isTriplanar, layerTexCoord, _LayerTiling0);

    isTriplanar = false;
#ifdef _LAYER_MAPPING_TRIPLANAR_1
    isTriplanar = true;
#endif
    ComputeLayerTexCoord1(  texCoord0, texCoord1, texCoord2, texCoord3, 
                            positionWS, normalWS, isTriplanar, layerTexCoord, _LayerTiling1);

    isTriplanar = false;
#ifdef _LAYER_MAPPING_TRIPLANAR_2
    isTriplanar = true;
#endif
    ComputeLayerTexCoord2(  texCoord0, texCoord1, texCoord2, texCoord3, 
                            positionWS, normalWS, isTriplanar, layerTexCoord, _LayerTiling2);

    isTriplanar = false;
#ifdef _LAYER_MAPPING_TRIPLANAR_3
    isTriplanar = true;
#endif
    ComputeLayerTexCoord3(  texCoord0, texCoord1, texCoord2, texCoord3, 
                            positionWS, normalWS, isTriplanar, layerTexCoord, _LayerTiling3);
}

void ApplyPerPixelDisplacement(FragInputs input, float3 V, inout LayerTexCoord layerTexCoord)
{
#if defined(_HEIGHTMAP) && defined(_PER_PIXEL_DISPLACEMENT)
    float3 viewDirTS = TransformWorldToTangent(V, input.tangentToWorld);
    int numSteps = (int)lerp(_PPDMaxSamples, _PPDMinSamples, viewDirTS.z);

    ParallaxOcclusionMappingLayer0(layerTexCoord, numSteps, viewDirTS);
    ParallaxOcclusionMappingLayer1(layerTexCoord, numSteps, viewDirTS);
    ParallaxOcclusionMappingLayer2(layerTexCoord, numSteps, viewDirTS);
    ParallaxOcclusionMappingLayer3(layerTexCoord, numSteps, viewDirTS);
#endif
}

float3 ComputeMainNormalInfluence(FragInputs input, float3 normalTS0, float3 normalTS1, float3 normalTS2, float3 normalTS3, LayerTexCoord layerTexCoord, float weights[_MAX_LAYER])
{
    // Get our regular normal from regular layering
    float3 normalTS = BlendLayeredVector3(normalTS0, normalTS1, normalTS2, normalTS3, weights);

    // THen get Main Layer Normal influence factor. Main layer is 0 because it can't be influence. In this case the final lerp return normalTS.
    float influenceFactor = BlendLayeredScalar(0.0, _InheritBaseNormal1, _InheritBaseNormal2, _InheritBaseNormal3, weights);
    // We will add smoothly the contribution of the normal map by using lower mips with help of bias sampling. InfluenceFactor must be [0..numMips] // Caution it cause banding...
    // Note: that we don't take details map into account here.
    float maxMipBias = log2(max(_NormalMap0_TexelSize.z, _NormalMap0_TexelSize.w)); // don't do + 1 as it is for bias, not lod
    float3 mainNormalTS = GetNormalTS0(input, layerTexCoord, float3(0.0, 0.0, 1.0), 0.0, true, maxMipBias * (1.0 - influenceFactor));

    // Add on our regular normal a bit of Main Layer normal base on influence factor. Note that this affect only the "visible" normal.
    return lerp(normalTS, BlendNormalRNM(normalTS, mainNormalTS), influenceFactor);
}

float3 ComputeMainBaseColorInfluence(float3 baseColor0, float3 baseColor1, float3 baseColor2, float3 baseColor3, float compoMask, LayerTexCoord layerTexCoord, float weights[_MAX_LAYER])
{
    float3 baseColor = BlendLayeredVector3(baseColor0, baseColor1, baseColor2, baseColor3, weights);

    float influenceFactor = BlendLayeredScalar(0.0, _InheritBaseColor1, _InheritBaseColor2, _InheritBaseColor3, weights);
    float influenceThreshold = BlendLayeredScalar(1.0, _InheritBaseColorThreshold1, _InheritBaseColorThreshold2, _InheritBaseColorThreshold3, weights);

    influenceFactor = influenceFactor * (1.0 - saturate(compoMask / influenceThreshold));

    // We want to calculate the mean color of the texture. For this we will sample a low mipmap
    float textureBias = 15.0; // Use maximum bias
    float3 baseMeanColor0 = SAMPLE_LAYER_TEXTURE2D_BIAS(_BaseColorMap0, sampler_BaseColorMap0, layerTexCoord.base0, textureBias).rgb *_BaseColor0.rgb;
    float3 baseMeanColor1 = SAMPLE_LAYER_TEXTURE2D_BIAS(_BaseColorMap1, sampler_BaseColorMap0, layerTexCoord.base1, textureBias).rgb *_BaseColor1.rgb;
    float3 baseMeanColor2 = SAMPLE_LAYER_TEXTURE2D_BIAS(_BaseColorMap2, sampler_BaseColorMap0, layerTexCoord.base2, textureBias).rgb *_BaseColor2.rgb;
    float3 baseMeanColor3 = SAMPLE_LAYER_TEXTURE2D_BIAS(_BaseColorMap3, sampler_BaseColorMap0, layerTexCoord.base3, textureBias).rgb *_BaseColor3.rgb;

    float3 meanColor = BlendLayeredVector3(baseMeanColor0, baseMeanColor1, baseMeanColor2, baseMeanColor3, weights);

    // If we inherit from base layer, we will add a bit of it
    // We add variance of current visible level and the base color 0 or mean (to retrieve initial color) depends on influence
    // (baseColor - meanColor) + lerp(meanColor, baseColor0, inheritBaseColor) simplify to
    return saturate(influenceFactor * (baseColor0 - meanColor) + baseColor);
}

// Caution: Blend mask are Layer 1 R - Layer 2 G - Layer 3 B - Main Layer A
float4 GetBlendMask(LayerTexCoord layerTexCoord, float4 vertexColor, bool useLodSampling = false, float lod = 0)
{
    // Caution: 
    // Blend mask are Main Layer A - Layer 1 R - Layer 2 G - Layer 3 B
    // Value for Mani layer is not use for blending itself but for alternate weighting like density.
    // Settings this specific Main layer blend mask in alpha allow to be transparent in case we don't use it and 1 is provide by default.
    float4 blendMasks = useLodSampling ? SAMPLE_LAYER_TEXTURE2D_LOD(_LayerMaskMap, sampler_LayerMaskMap, layerTexCoord.base0, lod) : SAMPLE_LAYER_TEXTURE2D(_LayerMaskMap, sampler_LayerMaskMap, layerTexCoord.base0);

#if defined(_LAYER_MASK_VERTEX_COLOR_MUL)
    blendMasks *= vertexColor;
#elif defined(_LAYER_MASK_VERTEX_COLOR_ADD)
    blendMasks = saturate(blendMasks + vertexColor * 2.0 - 1.0);
#endif

    return blendMasks;
}

// Calculate displacement for per vertex displacement mapping
float ComputePerVertexDisplacement(LayerTexCoord layerTexCoord, float4 vertexColor, float lod)
{
    float4 blendMasks = GetBlendMask(layerTexCoord, vertexColor, true, lod);

    float weights[_MAX_LAYER];
    ComputeMaskWeights(blendMasks, weights);

    float height0 = SampleHeightmapLod0(layerTexCoord, lod, _HeightCenterOffset0, _HeightFactor0);
    float height1 = SampleHeightmapLod1(layerTexCoord, lod, _HeightCenterOffset1, _HeightFactor1);
    float height2 = SampleHeightmapLod2(layerTexCoord, lod, _HeightCenterOffset2, _HeightFactor2);
    float height3 = SampleHeightmapLod3(layerTexCoord, lod, _HeightCenterOffset3, _HeightFactor3);
    float heightResult = BlendLayeredScalar(height0, height1, height2, height3, weights);

#if defined(_MAIN_LAYER_INFLUENCE_MODE)
    // Think that inheritbasedheight will be 0 if height0 is fully visible in weights. So there is no double contribution of height0
    float inheritBaseHeight = BlendLayeredScalar(0.0, _InheritBaseHeight1, _InheritBaseHeight2, _InheritBaseHeight3, weights);
    return heightResult + height0 * inheritBaseHeight;
#endif

    return heightResult;
}

float3 ApplyHeightBasedBlend(float3 inputMask, float3 inputHeight, float3 blendUsingHeight)
{
    return saturate(lerp(inputMask * inputHeight * blendUsingHeight * 100, 1, inputMask * inputMask)); // 100 arbitrary scale to limit blendUsingHeight values.
}

// Calculate weights to apply to each layer
// Caution: This function must not be use for per vertex of per pixel displacement, there is a dedicated function for them.
// this function handle triplanar
void ComputeLayerWeights(FragInputs input, LayerTexCoord layerTexCoord, float4 inputAlphaMask, out float outWeights[_MAX_LAYER])
{
    float4 blendMasks = GetBlendMask(layerTexCoord, input.color);

#if defined(_DENSITY_MODE)
    // Note: blendMasks.argb because a is main layer
    float4 minOpaParam = float4(_MinimumOpacity0, _MinimumOpacity1, _MinimumOpacity2, _MinimumOpacity3);
    float4 remapedOpacity = lerp(minOpaParam, float4(1.0, 1.0, 1.0, 1.0), inputAlphaMask); // Remap opacity mask from [0..1] to [minOpa..1]
    float4 opacityAsDensity = saturate((inputAlphaMask - (float4(1.0, 1.0, 1.0, 1.0) - blendMasks.argb)) * 20.0);

    float4 useOpacityAsDensityParam = float4(_OpacityAsDensity0, _OpacityAsDensity1, _OpacityAsDensity2, _OpacityAsDensity3);
    blendMasks.argb = lerp(blendMasks.argb * remapedOpacity, opacityAsDensity, useOpacityAsDensityParam);
#endif

#if defined(_HEIGHT_BASED_BLEND)
    float height0 = SampleHeightmap0(layerTexCoord, _HeightCenterOffset0, _HeightFactor0);
    float height1 = SampleHeightmap1(layerTexCoord, _HeightCenterOffset1, _HeightFactor1);
    float height2 = SampleHeightmap2(layerTexCoord, _HeightCenterOffset2, _HeightFactor2);
    float height3 = SampleHeightmap3(layerTexCoord, _HeightCenterOffset3, _HeightFactor3);
    float4 heights = float4(height0, height1, height2, height3);

    // HACK, use height0 to avoid compiler error for unused sampler
    // To remove once we have POM
    heights.y += (heights.x * 0.0001);

    // don't apply on main layer
    blendMasks.rgb = ApplyHeightBasedBlend(blendMasks.rgb, heights.yzw, float3(_BlendUsingHeight1, _BlendUsingHeight2, _BlendUsingHeight3));
#endif

    ComputeMaskWeights(blendMasks, outWeights);
}

void GetSurfaceAndBuiltinData(FragInputs input, float3 V, inout PositionInputs posInput, out SurfaceData surfaceData, out BuiltinData builtinData)
{
    LayerTexCoord layerTexCoord;
    GetLayerTexCoord(input.texCoord0, input.texCoord1, input.texCoord2, input.texCoord3,
                     input.positionWS, input.tangentToWorld[2].xyz, layerTexCoord);

    ApplyPerPixelDisplacement(input, V, layerTexCoord);

    float depthOffset = 0.0;
#ifdef _DEPTHOFFSET_ON
    ApplyDepthOffsetPositionInput(V, depthOffset, posInput);
#endif

    SurfaceData surfaceData0, surfaceData1, surfaceData2, surfaceData3;
    float3 normalTS0, normalTS1, normalTS2, normalTS3;
    float alpha0 = GetSurfaceData0(input, layerTexCoord, surfaceData0, normalTS0);
    float alpha1 = GetSurfaceData1(input, layerTexCoord, surfaceData1, normalTS1);
    float alpha2 = GetSurfaceData2(input, layerTexCoord, surfaceData2, normalTS2);
    float alpha3 = GetSurfaceData3(input, layerTexCoord, surfaceData3, normalTS3);

    // For layering we kill pixel based on maximun alpha
#ifdef _ALPHATEST_ON
#if _LAYER_COUNT == 2
    clip(max(alpha0, alpha1) - _AlphaCutoff);
#endif
#if _LAYER_COUNT == 3
    clip(max3(alpha0, alpha1, alpha2) - _AlphaCutoff);
#endif
#if _LAYER_COUNT == 4
    clip(max(alpha3, max3(alpha0, alpha1, alpha2)) - _AlphaCutoff);
#endif
#endif

    float weights[_MAX_LAYER];
    ComputeLayerWeights(input, layerTexCoord, float4(alpha0, alpha1, alpha2, alpha3), weights);

    // For layered shader, alpha of base color is used as either an opacity mask, a composition mask for inheritance parameters or a density mask.
    float alpha = PROP_BLEND_SCALAR(alpha, weights);

#if defined(_MAIN_LAYER_INFLUENCE_MODE)
    surfaceData.baseColor = ComputeMainBaseColorInfluence(surfaceData0.baseColor, surfaceData1.baseColor, surfaceData2.baseColor, surfaceData3.baseColor, alpha, layerTexCoord, weights);
    float3 normalTS = ComputeMainNormalInfluence(input, normalTS0, normalTS1, normalTS2, normalTS3, layerTexCoord, weights);
#else
    surfaceData.baseColor = SURFACEDATA_BLEND_VECTOR3(surfaceData, baseColor, weights);
    float3 normalTS = BlendLayeredVector3(normalTS0, normalTS1, normalTS2, normalTS3, weights);
#endif

    surfaceData.perceptualSmoothness = SURFACEDATA_BLEND_SCALAR(surfaceData, perceptualSmoothness, weights);
    surfaceData.ambientOcclusion = SURFACEDATA_BLEND_SCALAR(surfaceData, ambientOcclusion, weights);
    surfaceData.metallic = SURFACEDATA_BLEND_SCALAR(surfaceData, metallic, weights);

    // Init other unused parameter
    surfaceData.tangentWS = normalize(input.tangentToWorld[0].xyz);
    surfaceData.materialId = 0;
    surfaceData.anisotropy = 0;
    surfaceData.specular = 0.04;
    surfaceData.subsurfaceRadius = 1.0;
    surfaceData.thickness = 0.0;
    surfaceData.subsurfaceProfile = 0;
    surfaceData.coatNormalWS = float3(1.0, 0.0, 0.0);
    surfaceData.coatPerceptualSmoothness = 1.0;
    surfaceData.specularColor = float3(0.0, 0.0, 0.0);

    GetNormalAndTangentWS(input, V, normalTS, surfaceData.normalWS, surfaceData.tangentWS);
    // Done one time for all layered - cumulate with spec occ alpha for now
    surfaceData.specularOcclusion = SURFACEDATA_BLEND_SCALAR(surfaceData, specularOcclusion, weights);
    surfaceData.specularOcclusion *= GetHorizonOcclusion(V, surfaceData.normalWS, input.tangentToWorld[2].xyz, _HorizonFade);

    GetBuiltinData(input, surfaceData, alpha, depthOffset, builtinData);
}

#endif // #ifndef LAYERED_LIT_SHADER

#ifdef TESSELLATION_ON
#include "LitTessellation.hlsl" // Must be after GetLayerTexCoord() declaration
#endif
